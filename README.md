# Palworld Server Manager para Windows

## Instalación

1. Extraé toda la carpeta en una ubicación permanente, por ejemplo:
   `D:\Servidores\Palworld`
2. Ejecutá `INSTALAR_SERVIDOR.bat` como administrador.
3. Cuando termine, abrí `ABRIR_LAUNCHER.bat`.
4. Cambiá obligatoriamente la contraseña de administrador.
5. Guardá la configuración y arrancá el servidor.

## Estructura

- `steamcmd\`: SteamCMD.
- `server\`: Palworld Dedicated Server.
- `launcher\`: launcher gráfico PowerShell.
- `scripts\`: instalación y actualización.
- `backups\`: copias ZIP de `Pal\Saved`.
- `logs\`: salida del proceso del servidor.

## Internet y puertos

El puerto predeterminado es `8211/UDP`.

Para conexiones desde Internet:

1. Asigná una IP local fija a la PC del servidor.
2. Redirigí `UDP 8211` en el router a esa IP.
3. Permití el puerto en Firewall de Windows.
4. Los jugadores se conectan mediante `IP_PUBLICA:8211`.

Si tu proveedor utiliza CGNAT, la redirección de puertos puede no funcionar. En ese caso necesitás solicitar una IP pública o usar una VPN tipo Tailscale/ZeroTier.

## Funcionamiento del reinicio

El botón Reiniciar:

1. Crea un ZIP de la partida.
2. Detiene el proceso.
3. Espera.
4. Vuelve a iniciar el servidor.

La detención es primero normal y, si el proceso no responde, se fuerza luego de unos segundos. Para un apagado completamente limpio mediante comando `save`/`shutdown`, conviene añadir un cliente RCON en una segunda versión.

## Importante

No edites `DefaultPalWorldSettings.ini` esperando que afecte al servidor. El archivo activo es:

`server\Pal\Saved\Config\WindowsServer\PalWorldSettings.ini`


## Detección de la versión Xbox / Microsoft Store

El launcher busca Palworld instalado desde Xbox App/Microsoft Store mediante el paquete AppX/MSIX, el registro de aplicaciones y las carpetas `XboxGames`. Muestra la versión publicada por Windows o la versión del ejecutable WinGDK cuando está disponible.

El Steam Build ID del servidor y la versión Xbox pertenecen a esquemas distintos, por lo que el launcher no los declara iguales o diferentes de manera automática. Para evitar incompatibilidades, actualizá el servidor desde el launcher y el juego desde Xbox App.

## Corrección del error "Formato no reconocido"

La versión v4 repara automáticamente un `PalWorldSettings.ini` vacío o incompleto usando `DefaultPalWorldSettings.ini`.
También detiene temporalmente el servidor al guardar para evitar que Palworld sobrescriba los cambios al cerrarse.
Si el launcher todavía no abre correctamente, ejecutá una vez `REPARAR_CONFIGURACION.bat` y luego volvé a abrirlo.
