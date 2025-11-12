#!/bin/bash
# -----------------------------------------------------------------------------
# Copyright (c) 2025, Pablo German Saitta
# Licenciado bajo la Licencia MIT.
# Consulte el archivo LICENSE para obtener detalles.
# -----------------------------------------------------------------------------

#Funcion para mostrar el menu principal
mostrar_menu() {
	clear
	echo "============================================================"
	echo "=               MENU DE MONITOREO DEL SISTEMA              ="
	echo "============================================================"
	echo "1. Verificar espacio en disco y uso de archivos/directorios"
	echo "2. Mostrar consumo de memoria (RAM) y procesos top 5"
	echo "3. Mostrar consumo de CPU y procesos top 5"
	echo "4. Salir"
	echo "------------------------------------------------------------"
	echo -n "Selecciona una opcion [1-4]: "
}

# --- Opciones del menu ---

# Opcion 1: Espacio en Disco, 5 directorios/archivos con mas uso
opcion_disco(){
	clear
	echo "============================================================"
	echo "=            USO DEL ESPACIO EN DISCO Y ARCHIVOS           ="
	echo "============================================================"

	# 1. Espacio en disco 
	echo -e "\n### Espacio en Disco (General) ###"
	df -h | grep -E '^Filesystem|/dev/'

	# 2. Los 5 directorios con mas uso (desde el /)
	echo -e "\n### Top 5 Directorios con mas uso (puede demorar) ###"
	# Este comando busca recursivamente, ordena, y toma los 5 mayores (excluyendo la linea del total)
	sudo du -sh /* 2>/dev/null | sort -rh | head -n 5

	# 3. Los 5 archivos con mas uso (en /var/log y /home)
	echo -e "\n### Top 5 archivos con mas uso (en /var/log y /home ###"
	# Busca archivos mayores a 10Mb, ordena y muestra los primeros 5
	sudo find /var/log /home -type f -size +10M -exec du -h {} + 2>/dev/null | sort -rh | head -n 5

}

# Opcion 2: Consumo de Memoria y 5 procesos Top
opcion_memoria(){
	clear
	echo "========================================================"
	echo "=          CONSUMO DE MEMORIA RAM Y PROCESOS           ="
	echo "========================================================"

	# 1. Consumo de memoria general
	echo -e "\n### Resumen del Consumo de Memoria (RAM) ###"
	free -h

	# 2. Los 5 procesos con mas uso de memoria
	echo -e "\n### Top 5 procesos con mas uso de memoria RAM (%MEM) ###"
	# Muestra usuario, pid, %MEM y comando, ordenado por %MEM descendente
	ps -eo user,pid,%mem,cmd --sort=-%mem | head -n 6
}

# Opcion 3: Consumo de CPU y 5 procesos Top
opcion_cpu() {
	clear
	echo "========================================================="
	echo "=             CONSUMO DE CPU Y PROCESOS                 ="
	echo "========================================================="

	# 1. Consumo de CPU en general (con uptime y promedios de carga)
	echo -e "\n###   Top 5 Procesos con mas uso de CPU (%CPU)   ###"
	# Muestra usuario, PID, %CPU, y comando, ordenado por %CPU descendente
	ps -eo user,pid,%cpu,cmd --sort=-%cpu | head -n 6
}

# --- Bucle principal del Menu ---
while true; do
	mostrar_menu
	read opcion

	case $opcion in 
		1)
			opcion_disco
			echo -e "\nPresiona [enter] para volver al menu..."
			read
			;;

		2)
			opcion_memoria
			echo -e "\nPresiona [enter] para volver al menu..."
			read
			;;

		3)
			opcion_cpu
			echo -e "\nPresiona [enter] para volver al menu..."
			read
			;;

		4)
			echo -e "\n Saliendo del script. Gracias por usar software de Pablo Saitta"
			break
			;;

		*)
			echo -e "\n Opcion invalida. Intente nuevamente"
			sleep 2
			;;
	esac
done


