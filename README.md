# **Fedora System Update Script**

Ein robustes und automatisiertes Bash-Skript, um Fedora Linux effizient auf dem neuesten Stand zu halten. Das Skript aktualisiert sowohl die regulären Systempakete (via DNF) als auch isolierte Anwendungen (via Flatpak und Snap) in einem einzigen, abgesicherten Durchlauf.

## **🚀 Funktionen**

> * **Umfassendes Update:** Aktualisiert DNF-Pakete, Flatpak- und Snap-Anwendungen nacheinander.  
> * **Flexible Parameter:** Über Kommandozeilen-Parameter lassen sich optionale Schritte wie *dnf autoremove*, *Snap-Updates* und das *Logging* flexibel aktivieren.  
> * **Zentrales Logging:** Optionale Umleitung aller Ausgaben und Fehlermeldungen in eine definierte Logdatei.  
> * **Strikte Fehlerbehandlung:** Nutzt *set \-Eeuo pipefail* und einen ERR-Trap, um bei Problemen sofort und mit genauer Fehlerzeile abbrechen zu können.  
> * **Sudo-Keepalive:** Verhindert das Ablaufen des Sudo-Tickets bei großen Updates (z. B. umfangreichen Flatpak-Runtimes), sodass keine zweite Passworteingabe während des Vorgangs nötig ist.  
> * **Defensive Programmierung:** Prüft automatisch auf das Vorhandensein optionaler Komponenten (Flatpak, Snap, libnotify). Bei Snap wird zusätzlich validiert, ob der Systemd-Hintergrunddienst (snapd) aktiv ist. Fehlende Komponenten werden ohne Störmeldung übersprungen.  
> * **Neustart-Prüfung:** Ermittelt zuverlässig, ob nach dem Update ein Systemneustart empfohlen wird (z. B. nach einem Kernel-Update oder bei Kern-Bibliotheken). Warnt explizit bei fehlenden DNF-Plugins.  
> * **Desktop-Benachrichtigungen:** Sendet nach dem erfolgreichen Durchlauf eine native, sachlich korrekte Systembenachrichtigung (ideal für KDE Plasma oder GNOME).

## **📋 Systemanforderungen**

> * **Betriebssystem:** Fedora Linux (oder kompatible RHEL-basierte Distributionen)  
> * **Abhängigkeiten:** bash, sudo, dnf  
> * **Optional:** flatpak (für App-Updates), snapd (für Snap-Updates), libnotify (für Desktop-Benachrichtigungen via notify-send)

## **🛠️ Installation**

> 1. Das Repository klonen oder das Skript herunterladen.  
> 2. Das Skript ausführbar machen:  
>    chmod \+x update-system.sh  
> 3. **(Optional)** Das Skript in den lokalen Bin-Pfad verschieben, um es systemweit als Befehl (z. B. update-system) verfügbar zu machen:  
>    mkdir \-p \~/.local/bin  
>    mv update-system.sh \~/.local/bin/update-system*Hinweis: Möglicherweise muss das Terminal nach diesem Schritt neu gestartet werden.*

## **⚙️ Parameter & Konfiguration**

Das Skript wird nun primär über Kommandozeilen-Parameter beim Aufruf gesteuert:

> * **\--autoremove**: Führt nach dem DNF-Upgrade automatisch ein *dnf autoremove* aus, um ungenutzte Abhängigkeiten zu entfernen.  
> * **\--snap**: Aktiviert die Aktualisierung von Snap-Paketen (standardmäßig übersprungen, da Snap unter Fedora nicht vorinstalliert ist).  
> * **\--log \<Dateipfad\>**: Speichert die gesamte Terminalausgabe (inkl. Fehler) zusätzlich in der angegebenen Logdatei.

## **💻 Nutzung**

Standard-Aufruf (nur DNF & Flatpak, ohne Logging):

./update-system.sh

Aufruf mit allen Optionen (Autoremove, Snap-Updates und Logging):

./update-system.sh \--autoremove \--snap \--log mein-update.log

Wenn das Skript nach \~/.local/bin verschoben wurde, genügt der systemweite Aufruf:

update-system \--autoremove

Beim Start wird einmalig das Sudo-Passwort abgefragt. Danach läuft das Skript vollautomatisch durch.

## **🤖 Hinweis zur Erstellung**

Dieses Skript sowie die vorliegende Dokumentation wurden mit Unterstützung von Künstlicher Intelligenz (KI) erstellt und optimiert.

## **📄 Lizenz**

Dieses Projekt ist Open Source und steht unter der MIT-Lizenz. Der Quellcode kann frei verwendet, angepasst und weitergegeben werden.
