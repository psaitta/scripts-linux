#!/bin/bash

# -----------------------------------------------------------------------------
# Copyright (c) 2025, Pablo German Saitta
# Licenciado bajo la Licencia MIT.
# Consulte el archivo LICENSE para obtener detalles.
# -----------------------------------------------------------------------------

# --- Variables Globales ---
SFTP_BASE_DIR="/var/www/sftp"
SSHD_CONFIG="/etc/ssh/sshd_config"
# GID mínimo para considerar grupos de usuario, no de sistema.
MIN_GID=1000 
# ---

# Función para limpiar la pantalla y mostrar el menú principal
mostrar_menu_principal() {
    clear
    echo "======================================"
    echo "  Sistema de Gestión de Usuarios SFTP "
    echo "======================================"
    echo "1) Agregar usuario(s) a un grupo SFTP existente."
    echo "2) Crear un nuevo grupo SFTP, configurarlo y agregar usuario(s)."
    echo "3) Salir"
    echo "--------------------------------------"
    read -r -p "Seleccione una opción: " opcion_principal
}

# Función para obtener los grupos SFTP existentes
obtener_grupos_sftp() {
    echo "--- Grupos SFTP Detectados en $SSHD_CONFIG ---"
    
    # 1. Obtener grupos mencionados en la sección Match Group de sshd_config
    GRUPOS_SFTP=$(grep -i 'Match Group' "$SSHD_CONFIG" | awk '{print $NF}' | sort | uniq)
    
    if [ -z "$GRUPOS_SFTP" ]; then
        echo "No se encontraron grupos SFTP configurados con 'Match Group' en $SSHD_CONFIG."
        echo "Intentando obtener grupos con GID >= $MIN_GID:"
        GRUPOS_SFTP_FALLBACK=$(awk -F: -v min_gid="$MIN_GID" '$3 >= min_gid {print $1}' /etc/group | sort)
        
        if [ -z "$GRUPOS_SFTP_FALLBACK" ]; then
             echo "No se encontraron grupos de usuario (GID >= $MIN_GID) en /etc/group."
             return 1
        else
            echo "$GRUPOS_SFTP_FALLBACK"
            echo "----------------------------------------"
            echo "NOTA: Los grupos anteriores no están validados como SFTP en sshd_config."
            echo "----------------------------------------"
            GRUPOS_SFTP="$GRUPOS_SFTP_FALLBACK" 
        fi
    else
        echo "$GRUPOS_SFTP"
        echo "----------------------------------------"
    fi
    return 0
}

# Función para crear el nombre de usuario (ej: egiordano.spv1)
crear_nombre_usuario() {
    local nombre_completo="$1"
    local grupo="$2"
    
    local nombre=$(echo "$nombre_completo" | awk '{print $1}' | tr '[:upper:]' '[:lower:]')
    local apellido=$(echo "$nombre_completo" | awk '{print $NF}' | tr '[:upper:]' '[:lower:]')
    
    local primer_letra_nombre=${nombre:0:1}
    
    echo "${primer_letra_nombre}${apellido}.${grupo}"
}

# Función central para solicitar y crear un usuario
crear_usuario() {
    local grupo_destino="$1"
    
    echo ""
    echo "--- Creación de Usuario para el Grupo: $grupo_destino ---"
    
    read -r -p "Nombre y Apellido del usuario (Ej: Edgardo Giordano): " nombre_completo
    read -r -p "Comentario a asignar al usuario: " comentario_user
    
    local nuevo_usuario=$(crear_nombre_usuario "$nombre_completo" "$grupo_destino")
    
    echo "Nombre de usuario generado: **$nuevo_usuario**"
    
    # Comando useradd: -c (comentario), -M (sin home dir), -s /sbin/nologin (sólo SFTP), -g (grupo)
    echo "Ejecutando: useradd -c \"$comentario_user\" -M -s /sbin/nologin -g $grupo_destino $nuevo_usuario"
    if useradd -c "$comentario_user" -M -s /sbin/nologin -g "$grupo_destino" "$nuevo_usuario" ; then
        echo "Usuario **$nuevo_usuario** creado exitosamente."
        
        # Asignar contraseña
        while true; do
            echo "Por favor, ingrese la contraseña para el usuario **$nuevo_usuario**:"
            passwd "$nuevo_usuario" && break
        done
        
        return 0 
    else
        echo "Error al crear el usuario. Verifique los permisos o si el usuario/grupo ya existe."
        return 1
    fi
}

# Función para ingresar a un bucle de creación de múltiples usuarios
agregar_miembros_loop() {
    local grupo_destino="$1"
    
    while true; do
        echo "----------------------------------------"
        read -r -p "¿Desea agregar **otro** miembro al grupo '$grupo_destino'? (s/n): " agregar_miembro
        agregar_miembro=$(echo "$agregar_miembro" | tr '[:upper:]' '[:lower:]')
        
        if [[ "$agregar_miembro" == "s" || "$agregar_miembro" == "si" ]]; then
            crear_usuario "$grupo_destino" 
        elif [[ "$agregar_miembro" == "n" || "$agregar_miembro" == "no" ]]; then
            echo "Finalizando la adición de miembros para el grupo '$grupo_destino'."
            break
        else
            echo "Opción no válida. Por favor, responda 's' o 'n'."
        fi
    done
}


# --- Lógica Principal del Script ---
while true; do
    mostrar_menu_principal
    
    case $opcion_principal in
        1) # Agregar a grupo existente
            clear
            echo "--- Agregar Usuario(s) a Grupo Existente ---"
            echo "1) Mostrar grupos SFTP existentes."
            echo "2) Agregar usuario(s)."
            echo "3) Volver al menú principal."
            read -r -p "Seleccione una opción: " opcion_submenu
            
            case $opcion_submenu in
                1) # Mostrar grupos
                    echo ""
                    obtener_grupos_sftp
                    read -r -p "Presione [Enter] para continuar..."
                ;;
                2) # Agregar usuario(s)
                    echo ""
                    read -r -p "Ingrese el nombre del grupo SFTP existente al que desea agregar el usuario(s): " grupo_existente
                    
                    if getent group "$grupo_existente" >/dev/null; then
                        agregar_miembros_loop "$grupo_existente"
                    else
                        echo "¡ERROR! El grupo '$grupo_existente' no existe en el sistema."
                        read -r -p "Presione [Enter] para continuar..."
                    fi
                ;;
                3) # Volver
                    continue
                ;;
                *)
                    echo "Opción no válida. Intente de nuevo."
                    read -r -p "Presione [Enter] para continuar..."
                ;;
            esac
        ;;
        
        2) # Crear grupo, configurar y agregar miembros
            clear
            echo "--- Creación de Nuevo Grupo SFTP y Configuración ---"
            
            read -r -p "Nombre del nuevo grupo SFTP (Ej: spv1): " nuevo_grupo
            
            # 1. Crear el grupo
            echo "Ejecutando: groupadd $nuevo_grupo"
            if groupadd "$nuevo_grupo"; then
                echo "✅ Grupo **$nuevo_grupo** creado exitosamente."
            else
                echo "❌ ¡ERROR! Error al crear el grupo **$nuevo_grupo**. Ya podría existir."
                read -r -p "Presione [Enter] para continuar..."
                continue
            fi
            
            # 2. Crear la carpeta para el grupo y establecer permisos
            carpeta_grupo="$SFTP_BASE_DIR/$nuevo_grupo"
            echo "Creando directorio: $carpeta_grupo"
            mkdir -p "$carpeta_grupo"
            
            # Permisos: drwxr-xr-x (755), Propietario: root, Grupo: nuevo_grupo
            echo "Estableciendo propietario (root:$nuevo_grupo) y permisos (755) para $carpeta_grupo"
            chown root:"$nuevo_grupo" "$carpeta_grupo"
            chmod 755 "$carpeta_grupo"
            echo "✅ Directorio configurado exitosamente."
            
            # 3. Automatización de la configuración de SSHD y reinicio
            echo ""
            echo "--- Configurando SSHD para Chroot ---"
            
            # Se añade la configuración al final del sshd_config
            CONFIGURACION_SFTP=$(cat <<EOF
# --- Configuracion SFTP para grupo $nuevo_grupo (añadida por script) ---
Match Group $nuevo_grupo
  ChrootDirectory $carpeta_grupo
  ForceCommand internal-sftp
  AllowTcpForwarding no
  X11Forwarding no
# -------------------------------------------------------------------
EOF
)
            
            echo "$CONFIGURACION_SFTP" | tee -a "$SSHD_CONFIG" > /dev/null
            
            if [ $? -eq 0 ]; then
                echo "✅ Configuración agregada a $SSHD_CONFIG."
                
                # Reinicio del servicio SSHD
                echo "Reiniciando el servicio SSHD..."
                if systemctl restart sshd; then
                    echo "✅ Servicio SSHD reiniciado con éxito. El grupo está listo."
                else
                    echo "❌ ¡ERROR! No se pudo reiniciar el servicio SSHD. Verifique $SSHD_CONFIG."
                fi
            else
                echo "❌ ¡ERROR! No se pudo escribir en $SSHD_CONFIG. Revise permisos."
            fi
            
            # 4. Agregar miembros al nuevo grupo en un bucle
            echo ""
            echo "======================================"
            echo "   FASE DE ADICIÓN DE MIEMBROS"
            echo "======================================"
            agregar_miembros_loop "$nuevo_grupo"
            
            read -r -p "Presione [Enter] para volver al menú principal..."
        ;;
        
        3) # Salir
            echo "Saliendo del script. ¡Hasta luego!"
            exit 0
        ;;
        
        *) # Opción no válida
            echo "Opción no válida. Intente de nuevo."
            read -r -p "Presione [Enter] para continuar..."
        ;;
    esac
done
