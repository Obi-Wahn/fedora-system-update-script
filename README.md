# Fedora System Update Script

Ein robustes und automatisiertes Bash-Skript, um Fedora Linux effizient auf dem neuesten Stand zu halten. Das Skript aktualisiert sowohl die regulären Systempakete (via DNF) als auch isolierte Anwendungen (via Flatpak und optional Snap) in einem einzigen, abgesicherten Durchlauf.

## 🚀 Funktionen

* **Umfassendes Update:** Aktualisiert DNF-Pakete, Flatpak- und (optional) Snap-Anwendungen nacheinander.
* **Flexible Parameter:** Über Kommandozeilen-Parameter lassen sich optionale Schritte wie *dnf autoremove*, *Snap-Updates* und das *Logging* aktivieren.
* **Testlauf (Dry-Run):** Zeigt an, welche Befehle ausgeführt würden, ohne Änderungen am System vorzunehmen und ohne Administratorrechte anzufordern.
* **Integrierte Hilfe:** `--help` listet alle Parameter und Exit-Codes auf.
* **Zentrales Logging:** Optionale Umleitung aller Ausgaben und Fehlermeldungen in eine Logdatei (ohne Farbcodes).
* **Strikte Fehlerbehandlung:** Nutzt `set -Eeuo pipefail` und einen ERR-Trap, um bei Problemen sofort und mit genauer Fehlerzeile abzubrechen.
* **Sudo-Keepalive:** Verhindert das Ablaufen des Sudo-Tickets bei langen Updates, sodass keine zweite Passworteingabe während des Vorgangs nötig ist.
* **Defensive Programmierung:** Prüft automatisch auf das Vorhandensein optionaler Komponenten (Flatpak, Snap, libnotify). Bei Snap wird zusätzlich geprüft, ob der Systemd-Dienst (snapd) aktiv ist. Fehlende Komponenten werden mit einem kurzen Hinweis übersprungen.
* **Neustart-Prüfung:** Ermittelt, ob nach dem Update ein Systemneustart empfohlen wird (z. B. nach einem Kernel-Update oder bei Kern-Bibliotheken). Warnt explizit bei fehlendem DNF-Plugin.
* **Desktop-Benachrichtigungen:** Sendet nach Abschluss eines echten Update-Durchlaufs eine native Systembenachrichtigung (ideal für KDE Plasma oder GNOME).

## 📋 Systemanforderungen

* **Betriebssystem:** ausschließlich Fedora Linux (das Skript prüft `/etc/fedora-release` und bricht auf anderen Distributionen ab)
* **Abhängigkeiten:** `bash`, `sudo`, `dnf`, `rpm`, `uname`, `sort`, `date` sowie `tee` bei Nutzung von `--log` (auf Fedora standardmäßig vorhanden)
* **Optional:** `flatpak` (für App-Updates), `snapd` (für Snap-Updates), `libnotify` (für Desktop-Benachrichtigungen via `notify-send`)

## 🛠️ Installation

1. Das Repository klonen oder das Skript herunterladen.
2. Das Skript ausführbar machen:

   ```bash
   chmod +x update-system.sh
   ```

3. **(Optional)** Das Skript in den lokalen Bin-Pfad verschieben, um es als Befehl `update-system` verfügbar zu machen:

   ```bash
   mkdir -p ~/.local/bin
   mv update-system.sh ~/.local/bin/update-system
   ```

   *Hinweis: Wurde `~/.local/bin` gerade erst angelegt, muss das Terminal danach eventuell neu gestartet werden, damit der Ordner im `PATH` landet.*

## ⚙️ Parameter

| Parameter | Beschreibung |
|---|---|
| `--autoremove` | Führt nach dem DNF-Upgrade automatisch `dnf autoremove` aus, um ungenutzte Abhängigkeiten zu entfernen. |
| `--snap` | Aktiviert die Aktualisierung von Snap-Paketen (standardmäßig übersprungen, da Snap unter Fedora nicht vorinstalliert ist). |
| `--log <Dateipfad>` | Speichert die gesamte Terminalausgabe (inkl. Fehler) zusätzlich in der angegebenen Logdatei. Farben werden dabei deaktiviert. |
| `--dry-run` | Zeigt nur an, welche Befehle ausgeführt würden (DNF-Upgrade, Autoremove, Flatpak, Snap), ohne Änderungen am System vorzunehmen. Es werden keine Administratorrechte angefordert; der detaillierte Neustart-Check entfällt daher (eine bereits erkennbare neue Kernel-Version wird weiterhin angezeigt). Es wird keine Desktop-Benachrichtigung gesendet. |
| `-h`, `--help` | Zeigt eine Übersicht aller Parameter an und beendet das Skript. |

## 💻 Nutzung

Standard-Aufruf (nur DNF & Flatpak, ohne Logging):

```bash
./update-system.sh
```

Aufruf mit allen Optionen (Autoremove, Snap-Updates und Logging):

```bash
./update-system.sh --autoremove --snap --log mein-update.log
```

Testlauf ohne Änderungen am System:

```bash
./update-system.sh --dry-run
```

Wenn das Skript nach `~/.local/bin` verschoben wurde, genügt:

```bash
update-system --autoremove
```

Das Skript darf **nicht** mit `sudo` gestartet werden. Bei einem normalen Durchlauf wird zu Beginn einmalig das Sudo-Passwort abgefragt, danach läuft das Skript vollautomatisch durch. Im Dry-Run entfällt die Passwortabfrage.

## 🔢 Exit-Codes

| Code | Bedeutung |
|---|---|
| `0` | Alle Schritte erfolgreich bzw. Dry-Run abgeschlossen |
| `1` | Ungültiger Aufruf oder Update mit Teilfehlern (Flatpak/Snap) |
| sonstige | Abbruch durch einen fehlgeschlagenen Befehl (z. B. DNF); die Fehlerzeile wird ausgegeben |

Ein empfohlener Neustart ändert den Exit-Code nicht, sondern wird nur in der Ausgabe gemeldet.

## ⚠️ Bekannte Einschränkungen

* **dnf5 (Fedora 41+):** Seit Fedora 41 ist `dnf` ein Alias für `dnf5`. Die Neustart-Prüfung (`dnf needs-restarting -r`) benötigt dort das Paket `dnf5-plugins` (unter dnf4: `python3-dnf-plugins-core`). Das Verhalten unter dnf5 wurde für dieses Skript nicht auf einem echten System verifiziert.
* **Desktop-Benachrichtigungen:** `notify-send` wird nur aufgerufen, wenn eine aktive Desktop-Session erkannt wird (`DBUS_SESSION_BUS_ADDRESS` gesetzt). Bei einer reinen SSH-Sitzung wird die Benachrichtigung übersprungen.

## 🤖 Hinweis zur Erstellung

Dieses Skript sowie die vorliegende Dokumentation wurden mit Unterstützung von Künstlicher Intelligenz (KI) erstellt und optimiert.

## 📄 Lizenz

Dieses Projekt ist Open Source und steht unter der MIT-Lizenz. Der Quellcode kann frei verwendet, angepasst und weitergegeben werden.
