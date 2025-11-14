#!/bin/bash

# -----------------------------------------------------------------------------
# Copyright (c) 2025, Pablo German Saitta
# Licenciado bajo la Licencia MIT.
# Consulte el archivo LICENSE para obtener detalles.
# --------------------------------------------------------------------------

# =================================================================
# Variables de Configuración
# =================================================================
DESTINO_IP="192.168.0.74"
DESTINO_USER="ingops"
# Asumimos que la clave SSH para root@CentOS está configurada en ingops@Alma.

SSHD_CONFIG_ORIGEN="/etc/ssh/sshd_config"
SSHD_CONFIG_DESTINO="/tmp/sshd_config_migracion"

SFTP_DIR="/var/www/sftp"
SCRIPTS_DIR="/scripts"
CRONTAB_FILE="/tmp/root_crontab.bak"

MIN_ID=1000
# =================================================================

# -----------------------------------------------------------------
# Funciones de Soporte
# -----------------------------------------------------------------

# Función para ejecutar comandos con sudo en el destino usando SSH sin contraseña
ejecutar_remoto() {
    local comando="$1"
    
    echo " -> Ejecutando en ${DESTINO_IP} (con sudo): $comando"
    
    # Usamos "sudo sh -c" para asegurar que los pipes y redirecciones se ejecuten con sudo
    # Se añade '-T' para deshabilitar la asignación de TTY, lo que a veces ayuda con sudo NOPASSWD.
    ssh -o StrictHostKeyChecking=no -T "$DESTINO_USER@$DESTINO_IP" "sudo sh -c \"$comando\""
    
    if [ $? -ne 0 ]; then
        echo "❌ ERROR al ejecutar el comando remoto: $comando"
        echo "   Revise la configuración NOPASSWD para 'ingops' en el Alma Linux."
        # No salimos de aquí para permitir que el script intente continuar
        # Pero se debe revisar la salida del comando fallido.
        return 1
    fi
    return 0
}

# Función para ejecutar comandos como el usuario 'ingops' en el destino
ejecutar_remoto_user() {
    local comando="$1"
    
    echo " -> Ejecutando en ${DESTINO_IP} (como $DESTINO_USER): $comando"
    ssh -o StrictHostKeyChecking=no "$DESTINO_USER@$DESTINO_IP" "$comando"
    
    if [ $? -ne 0 ]; then
        echo "❌ ERROR al ejecutar el comando remoto como $DESTINO_USER."
        return 1
    fi
    return 0
}

# -----------------------------------------------------------------
# Paso 1: Verificación y Actualización Remota
# -----------------------------------------------------------------
paso_1_verificar_y_actualizar() {
    echo "==================================================="
    echo "1. Verificación Inicial y Actualización del Destino"
    echo "==================================================="
    
    echo "Comprobando conexión SSH sin contraseña a ${DESTINO_IP}..."
    if ! ejecutar_remoto_user "echo 'Conexión OK'" >/dev/null; then
        echo "❌ No se pudo establecer la conexión SSH. Ejecute los pasos de Configuración Previa (Clave SSH)."
        exit 1
    fi
    echo "✅ Conexión SSH establecida y clave configurada."
    
    echo "Instalando herramientas y verificando servicio SFTP en Alma Linux..."
    ejecutar_remoto "dnf install -y openssh-server rsync"
    echo "✅ Herramientas instaladas en el destino."
    
    echo "Actualizando el sistema Alma Linux..."
    ejecutar_remoto "dnf -y update"
    echo "✅ Alma Linux actualizado."
}

# -----------------------------------------------------------------
# Paso 2: Transferencia y Configuración de SSHD
# -----------------------------------------------------------------
paso_2_configurar_sshd() {
    echo "==================================================="
    echo "2. Configuración de SSHD"
    echo "==================================================="
    
    echo "Transfiriendo el archivo $SSHD_CONFIG_ORIGEN al destino..."
    rsync -avz "$SSHD_CONFIG_ORIGEN" "$DESTINO_USER@$DESTINO_IP:$SSHD_CONFIG_DESTINO"
    
    echo "Aplicando configuración SFTP del origen al destino..."
    
    SFTP_CONFIG_BLOCK_TRANSFER=$(cat <<EOF
cp /etc/ssh/sshd_config /etc/ssh/sshd_config.bak_\$(date +%Y%m%d);
# Asegura que la directiva Subsystem sftp internal-sftp esté presente y única
sed -i '/^Subsystem sftp/d' /etc/ssh/sshd_config; 
echo "Subsystem sftp internal-sftp" >> /etc/ssh/sshd_config;

# Añade la configuración del SFTP del archivo de origen
grep -E '^(Match Group|ChrootDirectory|ForceCommand|AllowTcpForwarding|X11Forwarding)' "$SSHD_CONFIG_DESTINO" >> /etc/ssh/sshd_config;

systemctl restart sshd;
rm -f "$SSHD_CONFIG_DESTINO"
EOF
)
    
    ejecutar_remoto "$SFTP_CONFIG_BLOCK_TRANSFER"
    echo "✅ Configuración de SSHD aplicada y servicio reiniciado en el destino."
}

# -----------------------------------------------------------------
# Paso 3: Migración de Grupos y Usuarios
# -----------------------------------------------------------------
paso_3_migrar_usuarios_y_grupos() {
    echo "==================================================="
    echo "3. Migración de Grupos y Usuarios (Corregido: -M, /sbin/nologin)"
    echo "==================================================="
    
    # 3.1 Migrar Grupos (Grupos con GID >= MIN_ID)
    echo "Migrando grupos de usuario..."
    
    # Se utiliza una variable temporal para contener el output del while loop
    GRUPOS_A_MIGRAR=$(cat /etc/group | awk -F: -v min_id="$MIN_ID" '$3 >= min_id {print $0}')
    
    echo "$GRUPOS_A_MIGRAR" | while IFS=: read -r G_NOMBRE G_PASS G_GID G_MIEMBROS; do
        echo " -> Procesando grupo: $G_NOMBRE (GID: $G_GID)"
        ejecutar_remoto "groupadd -f -g $G_GID $G_NOMBRE"
    done
    echo "✅ Grupos migrados."
    
    
    # 3.2 Migrar Usuarios (Usuarios con UID >= MIN_ID)
    echo "Migrando usuarios de SFTP (se pisarán si existen)..."
    
    # Se utiliza una variable temporal para contener el output del while loop
    USUARIOS_A_MIGRAR=$(cat /etc/passwd | awk -F: -v min_id="$MIN_ID" '$3 >= min_id {print $0}')

    echo "$USUARIOS_A_MIGRAR" | while IFS=: read -r U_NOMBRE U_PASS U_UID U_GID U_COMMENT U_HOME U_SHELL; do
        echo " -> Procesando usuario: $U_NOMBRE (UID: $U_UID)"
        
        # El comentario (U_COMMENT) se envuelve en comillas dobles "" para manejar espacios.
        # El comando useradd se envuelve en comillas simples '' y luego dobles "" para su ejecución remota segura.
        
        # 1. Eliminar si existe
        ejecutar_remoto "userdel -r $U_NOMBRE 2>/dev/null || true"
        
        # 2. Crear el usuario. Parámetros clave: -s /sbin/nologin -M (sin home).
        # Se elimina el -d "$U_HOME" que causaba problemas.
        if ! ejecutar_remoto "useradd -u $U_UID -g $U_GID -c '$U_COMMENT' -s /sbin/nologin -M $U_NOMBRE"; then
             echo "❌ Error al crear el usuario $U_NOMBRE. Continuando..."
             continue
        fi
        
        # 3. Transferir hash de la contraseña (Shadow)
        SHADOW_HASH=$(grep "^$U_NOMBRE:" /etc/shadow | awk -F: '{print $2}')
        if [ ! -z "$SHADOW_HASH" ]; then
            echo "   -> Transfiriendo hash de contraseña (shadow)..."
            ejecutar_remoto "usermod -p \"$SHADOW_HASH\" $U_NOMBRE"
        fi
    done
    echo "✅ Usuarios y contraseñas migrados."
}

# -----------------------------------------------------------------
# Paso 4: Transferencia de Datos
# -----------------------------------------------------------------
paso_4_transferir_datos() {
    echo "==================================================="
    echo "4. Transferencia de Datos y Scripts"
    echo "==================================================="
    
    # 4.0 Garantizar que los directorios principales existan y ingops pueda escribir.
    echo "Asegurando la existencia y propiedad de los directorios de destino..."
    ejecutar_remoto "mkdir -p $SFTP_DIR && chown -R $DESTINO_USER $SFTP_DIR"
    ejecutar_remoto "mkdir -p $SCRIPTS_DIR && chown -R $DESTINO_USER $SCRIPTS_DIR"
    echo "✅ Permisos de escritura asegurados para rsync."

    # 4.1 Transferir /var/www/sftp
    echo "Sincronizando $SFTP_DIR con permisos y IDs..."
    rsync -avzXA --delete "$SFTP_DIR/" "$DESTINO_USER@$DESTINO_IP:$SFTP_DIR/"
    if [ $? -ne 0 ]; then
        echo "❌ ERROR: Fallo en rsync para $SFTP_DIR."
        exit 1
    fi
    echo "✅ Datos de SFTP transferidos."
    
    # 4.2 Transferir /scripts
    echo "Sincronizando $SCRIPTS_DIR con permisos y IDs..."
    rsync -avzXA --delete "$SCRIPTS_DIR/" "$DESTINO_USER@$DESTINO_IP:$SCRIPTS_DIR/"
    if [ $? -ne 0 ]; then
        echo "❌ ERROR: Fallo en rsync para $SCRIPTS_DIR."
        exit 1
    fi
    echo "✅ Carpeta de scripts transferida."
    
    # 4.3 Transferir crontab de root
    echo "Transfiriendo crontab de root..."
    
    crontab -l > "$CRONTAB_FILE"
    
    rsync -avz "$CRONTAB_FILE" "$DESTINO_USER@$DESTINO_IP:$CRONTAB_FILE"
    
    # Cargar el crontab desde el archivo temporal en el destino (USANDO SUDO)
    ejecutar_remoto "crontab $CRONTAB_FILE && rm -f $CRONTAB_FILE"
    
    rm -f "$CRONTAB_FILE"
    echo "✅ Crontab de root transferido y cargado."
}


# -----------------------------------------------------------------
# Ejecución Principal
# -----------------------------------------------------------------
main() {
    clear
    echo "==================================================="
    echo "  INICIO DE LA MIGRACIÓN SFTP (CentOS 7 -> Alma 9) "
    echo "==================================================="
    
    if [ "$(id -u)" -ne 0 ]; then
        echo "❌ ¡ERROR! Este script debe ejecutarse como root en el CentOS 7 de origen."
        exit 1
    fi
    
    # Ejecutar los pasos en orden
    paso_1_verificar_y_actualizar
    paso_2_configurar_sshd
    paso_3_migrar_usuarios_y_grupos
    paso_4_transferir_datos
    
    echo "==================================================="
    echo "🎉 MIGRACIÓN COMPLETADA 🎉"
    echo "==================================================="
    echo "Pasos finales y verificación:"
    echo "* Asegúrese de que el usuario 'ingops' en el Alma Linux tenga 'NOPASSWD' en sudoers."
    echo "* Verifique el login de los usuarios SFTP: sftp <usuario>@${DESTINO_IP}"
}

main
