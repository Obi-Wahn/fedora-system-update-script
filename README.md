# Fedora System Update Script

Ein robustes und automatisiertes Bash-Skript, um Fedora Linux effizient auf dem neuesten Stand zu halten. Das Skript aktualisiert sowohl die regulären Systempakete (via DNF) als auch isolierte Anwendungen (via Flatpak und optional Snap) und auf Wunsch die Firmware (via fwupd) in einem einzigen, abgesicherten Durchlauf.

## 🚀 Funktionen

* **Umfassendes Update:** Aktualisiert DNF-Pakete, Flatpak- und (optional) Snap-Anwendungen nacheinander.
* **Flexible Parameter:** Über Kommandozeilen-Parameter lassen sich optionale Schritte wie *dnf autoremove*, *Snap-Updates* und das *Logging* aktivieren.
* **Firmware-Updates (optional):** Spielt mit `--firmware` Firmware-Updates über fwupd ein. Ein dafür nötiger Neustart wird nur empfohlen, nie automatisch ausgelöst.
* **Testlauf (Dry-Run):** Zeigt an, welche Befehle ausgeführt würden, ohne Änderungen am System vorzunehmen und ohne Administratorrechte anzufordern.
* **Integrierte Hilfe:** `--help` listet alle Parameter und Exit-Codes auf.
* **Zentrales Logging:** Optionale Umleitung aller Ausgaben und Fehlermeldungen in eine Logdatei (ohne Farbcodes).
* **Strikte Fehlerbehandlung:** Nutzt `set -Eeuo pipefail` und einen ERR-Trap, um bei Problemen sofort und mit genauer Fehlerzeile abzubrechen.
* **Sudo-Keepalive:** Verhindert das Ablaufen des Sudo-Tickets bei langen Updates, sodass keine zweite Passworteingabe während des Vorgangs nötig ist.
* **Defensive Programmierung:** Prüft automatisch auf das Vorhandensein optionaler Komponenten (Flatpak, Snap, fwupd, libnotify). Bei Snap wird zusätzlich geprüft, ob der Systemd-Dienst (snapd) aktiv ist. Fehlende Komponenten werden mit einem kurzen Hinweis übersprungen.
* **Neustart-Prüfung:** Ermittelt, ob nach dem Update ein Systemneustart empfohlen wird (z. B. nach einem Kernel-Update oder bei Kern-Bibliotheken). Warnt explizit bei fehlendem DNF-Plugin.
* **Desktop-Benachrichtigungen:** Sendet nach Abschluss eines echten Update-Durchlaufs eine native Systembenachrichtigung (ideal für KDE Plasma oder GNOME).

## 📋 Systemanforderungen

* **Betriebssystem:** ausschließlich Fedora Linux (das Skript prüft `/etc/fedora-release` und bricht auf anderen Distributionen ab)
* **Abhängigkeiten:** `bash`, `sudo`, `dnf`, `rpm`, `uname`, `sort`, `date` sowie `tee` bei Nutzung von `--log` (auf Fedora standardmäßig vorhanden)
* **Optional:** `flatpak` (für App-Updates), `snapd` (für Snap-Updates), `fwupd` (für Firmware-Updates), `libnotify` (für Desktop-Benachrichtigungen via `notify-send`)

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
| `--autoremove` | Entfernt nach den Updates nicht mehr benötigte Pakete (`dnf autoremove`) und ungenutzte Flatpak-Laufzeitumgebungen (`flatpak uninstall --unused`). Laufzeitumgebungen, die noch von einer App genutzt werden, bleiben erhalten. |
| `--snap` | Aktiviert die Aktualisierung von Snap-Paketen (standardmäßig übersprungen, da Snap unter Fedora nicht vorinstalliert ist). |
| `--firmware` | Spielt Firmware-Updates über fwupd ein (`fwupdmgr refresh`, `get-updates` und `update`). Gibt es keine Updates, ist das kein Fehler, und es wird nichts installiert. Ein Neustart wird nur empfohlen, wenn tatsächlich Firmware eingespielt wurde (viele UEFI-Updates werden erst beim nächsten Neustart installiert), aber nie automatisch ausgelöst. |
| `--log <Dateipfad>` | Speichert die gesamte Terminalausgabe (inkl. Fehler) zusätzlich in der angegebenen Logdatei. Farben werden dabei deaktiviert. |
| `--dry-run` | Zeigt nur an, welche Befehle ausgeführt würden (DNF-Upgrade, Autoremove, Flatpak, Snap), ohne Änderungen am System vorzunehmen. Es werden keine Administratorrechte angefordert; der detaillierte Neustart-Check entfällt daher (eine bereits erkennbare neue Kernel-Version wird weiterhin angezeigt). Es wird keine Desktop-Benachrichtigung gesendet. |
| `-h`, `--help` | Zeigt eine Übersicht aller Parameter an und beendet das Skript. |

## 💻 Nutzung

Standard-Aufruf (nur DNF & Flatpak, ohne Logging):

```bash
./update-system.sh
```

Aufruf mit allen Optionen (Autoremove, Snap- und Firmware-Updates, Logging):

```bash
./update-system.sh --autoremove --snap --firmware --log mein-update.log
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
| `1` | Ungültiger Aufruf, ungeeignete Umgebung (kein Fedora, Start als root) oder Update mit Teilfehlern (Flatpak/Snap/Firmware) |
| sonstige | Abbruch durch einen fehlgeschlagenen Befehl (z. B. DNF); die Fehlerzeile wird ausgegeben |

Ein empfohlener Neustart ändert den Exit-Code nicht, sondern wird nur in der Ausgabe gemeldet.

## 🩺 Fehlerbehebung

| Meldung | Ursache und Lösung |
|---|---|
| `Bitte das Skript NICHT als Root (mit sudo) starten!` | Das Skript ohne `sudo` starten; es fordert die Rechte selbst an. |
| `Erforderlicher Befehl fehlt: …` | Das genannte Werkzeug fehlt. Auf einem normalen Fedora-System ist das ungewöhnlich; das passende Paket nachinstallieren. |
| `Kann nicht in Logdatei schreiben: …` | Der Ordner existiert nicht oder ist nicht beschreibbar. Einen Pfad im eigenen Home-Verzeichnis wählen, z. B. `~/update.log`. |
| `Neustartstatus unklar (…)` | Das `needs-restarting`-Plugin fehlt: `sudo dnf install dnf5-plugins` (unter dnf4: `python3-dnf-plugins-core`). |
| `Snap ist zwar installiert, aber der snapd-Dienst ist nicht aktiv.` | Snap-Dienst aktivieren: `sudo systemctl enable --now snapd.socket` |
| `Flatpak-Update meldete einen Fehler` | `flatpak update` von Hand ausführen, um die genaue Fehlermeldung zu sehen; mit `flatpak remotes` prüfen, ob die Quellen (z. B. Flathub) eingerichtet sind. |
| `Nicht alle Firmware-Updates wurden eingespielt` | fwupd hat ein Update übersprungen, meist weil es eine Benutzeraktion braucht (z. B. Netzteil anschließen, Akku laden). Die Ausgabe von fwupd nennt den Grund; danach das Skript erneut mit `--firmware` starten. |
| `Firmware-Update meldete einen Fehler` | `fwupdmgr update` von Hand ausführen, um die genaue Fehlermeldung zu sehen; `fwupdmgr get-devices` zeigt, welche Geräte fwupd unterstützt. |

**Unbeaufsichtigte Updates (Cron, Timer):** Das Skript ist für den interaktiven Einsatz gedacht, weil es zu Beginn das Sudo-Passwort abfragt. Für automatische Updates ist auf Fedora `dnf-automatic` das passende Werkzeug (ab Fedora 41: Paket `dnf5-plugin-automatic`, Timer `dnf5-automatic.timer`).

## ⚠️ Bekannte Einschränkungen

* **dnf5 (Fedora 41+):** Seit Fedora 41 ist `dnf` ein Alias für `dnf5`. Die Neustart-Prüfung (`dnf needs-restarting -r`) benötigt dort das Paket `dnf5-plugins` (unter dnf4: `python3-dnf-plugins-core`). Unter dnf5 5.4 (Fedora 44) wird `-r` nur noch aus Kompatibilitätsgründen akzeptiert und hat keine eigene Wirkung, der Aufruf funktioniert also. Einen nötigen Neustart meldet `needs-restarting` mit Exit-Code 1; weil auch Fehler (z. B. ein fehlendes Plugin) mit 1 enden, prüft das Skript zusätzlich den Ausgabetext „Reboot is required“. Das Verhalten ist dem dnf5-Quelltext entnommen. Auf einem echten Fedora-44-System bestätigt ist bisher der Fall ohne nötigen Neustart; der Fall „Neustart nötig“ wurde dort noch nicht beobachtet.
* **Flatpak:** `flatpak update` aktualisiert sowohl Benutzer- als auch systemweite Installationen. Bei systemweiten Installationen kann polkit nach einem Passwort fragen, z. B. bei einer SSH-Sitzung.
* **Desktop-Benachrichtigungen:** `notify-send` wird nur aufgerufen, wenn eine aktive Desktop-Session erkannt wird (`DBUS_SESSION_BUS_ADDRESS` gesetzt). Bei einer reinen SSH-Sitzung wird die Benachrichtigung übersprungen.

## 🧪 Entwicklung & Tests

Bei jedem Push auf `main` und bei jedem Pull Request prüft GitHub Actions das Skript mit `shellcheck` und führt die Tests in einem Fedora-Container aus.

Die Tests liegen in `tests/` und nutzen [bats](https://github.com/bats-core/bats-core). Alle Systembefehle (`sudo`, `dnf`, `rpm`, `flatpak`, `fwupdmgr`, …) werden dabei durch Attrappen ersetzt, am System wird also nichts verändert. Lokal laufen sie auf Fedora als normaler Benutzer:

```bash
sudo dnf install bats ShellCheck
shellcheck update-system.sh
bats tests/
```

## 🤖 Hinweis zur Erstellung

Dieses Skript sowie die vorliegende Dokumentation wurden mit Unterstützung von Künstlicher Intelligenz (KI) erstellt und optimiert.

## 📄 Lizenz

Dieses Projekt ist Open Source und steht unter der MIT-Lizenz. Der Quellcode kann frei verwendet, angepasst und weitergegeben werden.
