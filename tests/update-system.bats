#!/usr/bin/env bats
# Tests für update-system.sh. Alle Systembefehle (sudo, dnf, rpm, flatpak, ...) werden
# durch protokollierende Attrappen ersetzt, es wird also nichts am System verändert.
# Voraussetzung: Fedora (das Skript prüft /etc/fedora-release) und ein normaler Benutzer.

SCRIPT="$BATS_TEST_DIRNAME/../update-system.sh"

setup_file() {
    if [[ ! -r /etc/fedora-release ]]; then
        echo "Die Tests müssen auf Fedora laufen (/etc/fedora-release fehlt)." >&2
        return 1
    fi
    if [[ $EUID -eq 0 ]]; then
        echo "Die Tests müssen als normaler Benutzer laufen, das Skript verweigert root." >&2
        return 1
    fi
}

setup() {
    MOCKBIN="$BATS_TEST_TMPDIR/bin"
    CALLS="$BATS_TEST_TMPDIR/calls.log"
    mkdir -p "$MOCKBIN"
    : > "$CALLS"

    # Nur diese echten Werkzeuge stehen im PATH, damit lokal installierte
    # flatpak/snap/fwupdmgr/notify-send die Ergebnisse nicht beeinflussen.
    local tool
    for tool in cat date env mktemp rm sleep sort tail tee touch uname; do
        ln -s "$(command -v "$tool")" "$MOCKBIN/$tool"
    done

    mock sudo '[[ "$1" == -v || "$1" == -n ]] && exit 0; exec "$@"'
    mock dnf 'if [[ "$1" == needs-restarting ]]; then echo "${MOCK_NEEDS_RESTARTING_OUTPUT:-}"; exit "${MOCK_NEEDS_RESTARTING_RC:-0}"; fi'
    mock rpm '[[ -n "${MOCK_KERNEL:-}" ]] || exit 1; [[ "$*" == *--queryformat* ]] && echo "$MOCK_KERNEL"; exit 0'
}

# Legt eine Attrappe an, die ihren Aufruf in $CALLS protokolliert und dann <body> ausführt.
mock() {
    local name=$1 body=${2:-exit 0}
    printf '#!/bin/bash\necho "%s $*" >> "%s"\n%s\n' "$name" "$CALLS" "$body" > "$MOCKBIN/$name"
    chmod +x "$MOCKBIN/$name"
}

run_script() {
    run env -u DBUS_SESSION_BUS_ADDRESS -u NO_COLOR -u XDG_DATA_DIRS PATH="$MOCKBIN" /bin/bash "$SCRIPT" "$@" 3>&-
}

called() {
    grep -qxF -- "$1" "$CALLS" || { echo "Erwarteter Aufruf fehlt: $1" >&2; cat "$CALLS" >&2; return 1; }
}

not_called() {
    if grep -q -- "$1" "$CALLS"; then
        echo "Unerwarteter Aufruf: $1" >&2
        cat "$CALLS" >&2
        return 1
    fi
}

# --- Parameter -------------------------------------------------------------

@test "--help zeigt die Verwendung und endet mit 0" {
    run_script --help
    [ "$status" -eq 0 ]
    [[ "$output" == *"Verwendung: update-system.sh"* ]]
    [[ "$output" == *"--firmware"* ]]
}

@test "unbekannter Parameter endet mit 1" {
    run_script --gibtsnicht
    [ "$status" -eq 1 ]
    [[ "$output" == *"Unbekannter Parameter: --gibtsnicht"* ]]
}

@test "--log ohne Dateipfad endet mit 1" {
    run_script --log
    [ "$status" -eq 1 ]
    [[ "$output" == *"Fehlendes Argument für --log"* ]]
}

@test "--log in einen nicht vorhandenen Ordner endet mit 1" {
    run_script --log "$BATS_TEST_TMPDIR/fehlt/update.log"
    [ "$status" -eq 1 ]
    [[ "$output" == *"Kann nicht in Logdatei schreiben"* ]]
}

@test "--log schreibt die Ausgabe in die Logdatei" {
    local logfile="$BATS_TEST_TMPDIR/update.log"
    run_script --dry-run --log "$logfile"
    [ "$status" -eq 0 ]
    grep -q "Dry-Run abgeschlossen" "$logfile"
}

@test "--log schreibt keine Farbcodes, auch wenn ein Terminal angeschlossen ist" {
    command -v script >/dev/null || skip "'script' (util-linux) ist nicht installiert"
    local logfile="$BATS_TEST_TMPDIR/update.log"

    # Gegenprobe: Ohne --log erscheinen am Terminal Farben
    run script -qec "env -u NO_COLOR PATH='$MOCKBIN' /bin/bash '$SCRIPT' --dry-run" /dev/null 3>&-
    [ "$status" -eq 0 ]
    [[ "$output" == *$'\033['* ]]

    run script -qec "env -u NO_COLOR PATH='$MOCKBIN' /bin/bash '$SCRIPT' --dry-run --log '$logfile'" /dev/null 3>&-
    [ "$status" -eq 0 ]
    grep -q "Dry-Run abgeschlossen" "$logfile"
    [ "$(grep -c $'\033' "$logfile" || true)" -eq 0 ]
}

# --- Dry-Run ---------------------------------------------------------------

@test "Dry-Run ruft sudo nie auf und meldet keinen Update-Erfolg" {
    mock flatpak
    mock notify-send
    run env -u NO_COLOR DBUS_SESSION_BUS_ADDRESS=unix:path=/dev/null PATH="$MOCKBIN" \
        /bin/bash "$SCRIPT" --dry-run --autoremove 3>&-
    [ "$status" -eq 0 ]
    [[ "$output" == *"[DRY-RUN] Würde ausführen: sudo dnf upgrade --refresh -y"* ]]
    [[ "$output" == *"[DRY-RUN] Würde ausführen: sudo dnf autoremove -y"* ]]
    [[ "$output" == *"[DRY-RUN] Würde ausführen: sudo env FLATPAK_FANCY_OUTPUT=0 FLATPAK_USER_DIR="*"flatpak update --system -y"* ]]
    [[ "$output" == *"[DRY-RUN] Würde ausführen: sudo env FLATPAK_FANCY_OUTPUT=0 FLATPAK_USER_DIR="*"flatpak uninstall --system --unused -y"* ]]
    [[ "$output" == *"Dry-Run abgeschlossen"* ]]
    [[ "$output" != *"ohne Fehler ausgeführt"* ]]
    not_called "^sudo"
    # Nur das lesende 'flatpak list' ist im Dry-Run erlaubt
    not_called "^flatpak update"
    not_called "^flatpak uninstall"
    not_called "^notify-send"
}

# --- Normaler Lauf ---------------------------------------------------------

@test "normaler Lauf aktualisiert über sudo und meldet Erfolg" {
    run_script
    [ "$status" -eq 0 ]
    called "sudo -v"
    called "sudo dnf upgrade --refresh -y"
    not_called "autoremove"
    [[ "$output" == *"Alle vorgesehenen Update-Schritte wurden ohne Fehler ausgeführt"* ]]
    [[ "$output" == *"Kein Neustart erforderlich"* ]]
}

@test "Skript endet sofort, auch wenn die Ausgabe in eine Pipe geht" {
    local start=$SECONDS
    run_script
    [ "$status" -eq 0 ]
    [ $((SECONDS - start)) -lt 10 ]
}

@test "--autoremove führt dnf autoremove aus" {
    run_script --autoremove
    [ "$status" -eq 0 ]
    called "sudo dnf autoremove -y"
}

@test "Desktop-Benachrichtigung nur mit aktiver Session" {
    mock notify-send
    run_script
    not_called "^notify-send"

    run env DBUS_SESSION_BUS_ADDRESS=unix:path=/dev/null PATH="$MOCKBIN" /bin/bash "$SCRIPT" 3>&-
    [ "$status" -eq 0 ]
    grep -q "^notify-send System-Update abgeschlossen" "$CALLS"
}

# --- Flatpak & Snap --------------------------------------------------------

@test "fehlgeschlagenes Flatpak-Update ergibt Teilfehler und Exit-Code 1" {
    mock flatpak 'exit 1'
    run_script
    [ "$status" -eq 1 ]
    [[ "$output" == *"Update mit Teilfehlern abgeschlossen (Flatpak)"* ]]
}

@test "Flatpak-Systeminstallation wird über sudo aktualisiert" {
    mock flatpak
    run_script
    [ "$status" -eq 0 ]
    grep -qx "sudo env FLATPAK_FANCY_OUTPUT=0 FLATPAK_USER_DIR=$HOME/.local/share/flatpak XDG_DATA_DIRS=/var/lib/flatpak/exports/share:/usr/local/share:/usr/share flatpak update --system -y" "$CALLS"
    called "flatpak update --system -y"
}

@test "Flatpak zeichnet keine Fortschrittstabelle (FLATPAK_FANCY_OUTPUT=0)" {
    mock flatpak 'echo "fancy $1=${FLATPAK_FANCY_OUTPUT:-}" >> "'"$CALLS"'"'
    run_script --autoremove
    [ "$status" -eq 0 ]
    called "fancy update=0"
    called "fancy uninstall=0"
}

@test "Flatpak-Benutzerinstallation wird nur aktualisiert, wenn dort etwas installiert ist" {
    mock flatpak
    run_script
    [ "$status" -eq 0 ]
    not_called "flatpak update --user"

    : > "$CALLS"
    mock flatpak '[[ "$1" == list && "$2" == --user ]] && echo app/org.example.App/x86_64/stable; exit 0'
    run_script --autoremove
    [ "$status" -eq 0 ]
    called "flatpak update --user -y"
    called "flatpak uninstall --user --unused -y"
    # Die Benutzerinstallation braucht keine Adminrechte
    not_called "^sudo .*--user"
}

@test "--autoremove entfernt ungenutzte Flatpak-Laufzeitumgebungen" {
    mock flatpak
    run_script --autoremove
    [ "$status" -eq 0 ]
    called "flatpak update --system -y"
    # FLATPAK_USER_DIR sorgt dafür, dass flatpak auch als root die Benutzer-Apps des Aufrufers berücksichtigt
    grep -qx "sudo env FLATPAK_FANCY_OUTPUT=0 FLATPAK_USER_DIR=$HOME/.local/share/flatpak XDG_DATA_DIRS=/var/lib/flatpak/exports/share:/usr/local/share:/usr/share flatpak uninstall --system --unused -y" "$CALLS"
}

@test "Flatpak-Aufräumen beachtet XDG_DATA_HOME für die Benutzerinstallation" {
    mock flatpak
    run env -u DBUS_SESSION_BUS_ADDRESS -u XDG_DATA_DIRS XDG_DATA_HOME="$BATS_TEST_TMPDIR/data" PATH="$MOCKBIN" /bin/bash "$SCRIPT" --autoremove 3>&-
    [ "$status" -eq 0 ]
    grep -q "^sudo env FLATPAK_FANCY_OUTPUT=0 FLATPAK_USER_DIR=$BATS_TEST_TMPDIR/data/flatpak XDG_DATA_DIRS=/var/lib/flatpak/exports/share:/usr/local/share:/usr/share flatpak uninstall" "$CALLS"
}

@test "genutzte EOL-Laufzeitumgebung wird nicht entfernt, nur erwähnt" {
    mock flatpak 'if [[ "$1" == update ]]; then
cat <<OUT
Info: runtime org.freedesktop.Platform branch 24.08 is end-of-life, with reason:
   org.freedesktop.Platform 24.08 is no longer receiving fixes and security updates.
Info: applications using this runtime:
   org.processing.pde

Info: runtime org.freedesktop.Platform.GL.default branch 24.08 is end-of-life, with reason:
   org.freedesktop.Platform 24.08 is no longer receiving fixes and security updates.
Info: applications using this extension:
   org.processing.pde
OUT
fi'
    run_script --autoremove
    [ "$status" -eq 0 ]
    [[ "$output" == *"Hinweis: Veraltete Flatpak-Laufzeitumgebungen (end-of-life) werden noch genutzt und bleiben daher installiert. Betroffene Apps: org.processing.pde."* ]]
    # Nur 'uninstall --unused', nie ein gezieltes Entfernen der EOL-Laufzeitumgebung
    not_called "^flatpak uninstall .*org.freedesktop"
    [ "$(grep -c '^flatpak uninstall' "$CALLS")" -eq 1 ]
}

@test "ohne EOL-Meldung von flatpak gibt es keinen EOL-Hinweis" {
    mock flatpak
    run_script
    [ "$status" -eq 0 ]
    [[ "$output" != *"end-of-life"* ]]
}

@test "ohne --autoremove bleiben Flatpak-Laufzeitumgebungen unangetastet" {
    mock flatpak
    run_script
    [ "$status" -eq 0 ]
    not_called "^flatpak uninstall"
}

@test "Fehler beim Flatpak-Aufräumen ergibt Teilfehler und Exit-Code 1" {
    mock flatpak '[[ "$1" == uninstall ]] && exit 1; exit 0'
    run_script --autoremove
    [ "$status" -eq 1 ]
    [[ "$output" == *"Update mit Teilfehlern abgeschlossen (Flatpak-Aufräumen)"* ]]
}

@test "Flatpak-Fortschrittszeilen nennen die ID des gerade aktualisierten Eintrags" {
    mock flatpak 'if [[ "$1" == update ]]; then
cat <<OUT
Suche nach Aktualisierungen …


        ID                                  Zweig    Op   Entfernte Quelle   Herunterladen
 1.     org.freedesktop.Platform.GL.default 25.08    u    flathub            < 150,2 MB
 2.     org.mozilla.firefox                 stable   u    flathub            < 98,1 MB


Aktualisiere 1/2 …
Aktualisiere 1/2 …  ██████              30%  3,3 MB/s  00:12
Aktualisiere 2/2 …
Aktualisiere 2/2 …  ████████████████████ 100%  4,2 MB/s  00:00
Updating 2/2…
Aktualisiere 3/2 …
OUT
fi'
    run_script
    [ "$status" -eq 0 ]
    [[ "$output" == *"Aktualisiere 1/2 org.freedesktop.Platform.GL.default …"$'\n'* ]]
    [[ "$output" == *"Aktualisiere 1/2 org.freedesktop.Platform.GL.default …  ██████              30%  3,3 MB/s  00:12"* ]]
    [[ "$output" == *"Aktualisiere 2/2 org.mozilla.firefox …  ████████████████████ 100%"* ]]
    # Englische Ausgabe (ohne Leerzeichen vor dem "…") wird ebenso ergänzt
    [[ "$output" == *"Updating 2/2 org.mozilla.firefox…"* ]]
    # Die Tabelle bleibt unverändert, unbekannte Nummern ebenso
    [[ "$output" == *" 2.     org.mozilla.firefox                 stable   u    flathub            < 98,1 MB"* ]]
    [[ "$output" == *"Aktualisiere 3/2 …"* ]]
}

@test "XDG_DATA_DIRS des Aufrufers wird an flatpak über sudo weitergegeben" {
    mock flatpak
    # Bereits enthalten: unverändert weitergeben
    run env -u DBUS_SESSION_BUS_ADDRESS XDG_DATA_DIRS=/home/x/.local/share/flatpak/exports/share:/var/lib/flatpak/exports/share:/usr/share \
        PATH="$MOCKBIN" /bin/bash "$SCRIPT" 3>&-
    [ "$status" -eq 0 ]
    grep -q "^sudo env .* XDG_DATA_DIRS=/home/x/.local/share/flatpak/exports/share:/var/lib/flatpak/exports/share:/usr/share flatpak update --system -y$" "$CALLS"

    # Fehlt das Exportverzeichnis, wird es vorangestellt
    : > "$CALLS"
    run env -u DBUS_SESSION_BUS_ADDRESS XDG_DATA_DIRS=/usr/share PATH="$MOCKBIN" /bin/bash "$SCRIPT" 3>&-
    [ "$status" -eq 0 ]
    grep -q "^sudo env .* XDG_DATA_DIRS=/var/lib/flatpak/exports/share:/usr/share flatpak update --system -y$" "$CALLS"
}

@test "fehlendes Flatpak ist nur ein Hinweis" {
    run_script
    [ "$status" -eq 0 ]
    [[ "$output" == *"Flatpak ist nicht installiert. Übersprungen."* ]]
}

@test "Snap wird bei inaktivem snapd übersprungen" {
    mock snap
    mock systemctl 'exit 3'
    run_script --snap
    [ "$status" -eq 0 ]
    [[ "$output" == *"snapd-Dienst ist nicht aktiv"* ]]
    not_called "^snap refresh"
}

@test "Snap wird bei aktivem snapd aktualisiert" {
    mock snap
    mock systemctl
    run_script --snap
    [ "$status" -eq 0 ]
    called "sudo snap refresh"
}

# --- Firmware --------------------------------------------------------------

# fwupdmgr-Attrappe, Exit-Codes je Unterbefehl über Umgebungsvariablen steuerbar.
# 'get-updates' liefert beim ersten Aufruf MOCK_FW_GET_UPDATES_RC (Standard 0 = Updates verfügbar),
# bei jedem weiteren Aufruf MOCK_FW_AFTER_RC (Standard 2 = alles eingespielt).
mock_fwupd() {
    mock fwupdmgr 'case "$1" in
    refresh) exit "${MOCK_FW_REFRESH_RC:-0}" ;;
    get-updates)
        if [[ -e "$0.state" ]]; then exit "${MOCK_FW_AFTER_RC:-2}"; fi
        touch "$0.state"
        exit "${MOCK_FW_GET_UPDATES_RC:-0}" ;;
    update) exit "${MOCK_FW_UPDATE_RC:-0}" ;;
esac'
}

@test "Firmware wird ohne --firmware nicht angefasst" {
    mock_fwupd
    run_script
    [ "$status" -eq 0 ]
    not_called "^fwupdmgr"
}

@test "Firmware-Update startet den Rechner nie selbst neu" {
    mock_fwupd
    run_script --firmware
    [ "$status" -eq 0 ]
    called "sudo fwupdmgr refresh"
    called "sudo fwupdmgr get-updates --no-unreported-check"
    called "sudo fwupdmgr update -y --no-reboot-check --no-unreported-check"
    [[ "$output" == *"Neustart empfohlen (Firmware aktualisiert"* ]]
}

@test "Firmware: ohne verfügbare Updates wird nichts installiert und kein Neustart empfohlen" {
    export MOCK_FW_GET_UPDATES_RC=2
    mock_fwupd
    run_script --firmware
    [ "$status" -eq 0 ]
    not_called "^fwupdmgr update"
    [[ "$output" == *"Keine Firmware-Updates verfügbar"* ]]
    [[ "$output" == *"Kein Neustart erforderlich"* ]]
}

@test "Firmware: bereits aktuelle Metadaten (refresh mit Code 2) sind kein Fehler" {
    export MOCK_FW_REFRESH_RC=2
    mock_fwupd
    run_script --firmware
    [ "$status" -eq 0 ]
    called "sudo fwupdmgr update -y --no-reboot-check --no-unreported-check"
}

@test "Firmware: nicht eingespielte Updates (z.B. ohne Netzteil) ergeben eine Warnung statt Neustart-Empfehlung" {
    export MOCK_FW_AFTER_RC=0
    mock_fwupd
    run_script --firmware
    [ "$status" -eq 1 ]
    [[ "$output" == *"Nicht alle Firmware-Updates wurden eingespielt"* ]]
    [[ "$output" != *"Firmware aktualisiert"* ]]
}

@test "Firmware: Fehler beim Einspielen ergibt Teilfehler und Exit-Code 1" {
    export MOCK_FW_UPDATE_RC=1
    mock_fwupd
    run_script --firmware
    [ "$status" -eq 1 ]
    [[ "$output" == *"Update mit Teilfehlern abgeschlossen (Firmware)"* ]]
}

@test "Firmware: Fehler beim Aktualisieren der Metadaten überspringt das Update" {
    export MOCK_FW_REFRESH_RC=1
    mock_fwupd
    run_script --firmware
    [ "$status" -eq 1 ]
    not_called "^fwupdmgr get-updates"
    not_called "^fwupdmgr update"
}

@test "Firmware: fehlendes fwupd ist nur ein Hinweis" {
    run_script --firmware
    [ "$status" -eq 0 ]
    [[ "$output" == *"fwupd ist nicht installiert"* ]]
}

@test "Firmware: Dry-Run zeigt die Befehle nur an" {
    mock_fwupd
    run_script --firmware --dry-run
    [ "$status" -eq 0 ]
    [[ "$output" == *"[DRY-RUN] Würde ausführen: sudo fwupdmgr get-updates --no-unreported-check"* ]]
    [[ "$output" == *"[DRY-RUN] Würde ausführen: sudo fwupdmgr update -y --no-reboot-check"* ]]
    not_called "^fwupdmgr"
}

# --- Neustart-Prüfung ------------------------------------------------------

@test "neuerer installierter Kernel führt zur Neustart-Empfehlung mit beiden Versionen" {
    export MOCK_KERNEL="999.0.1-1.fc99.x86_64"
    run_script
    [ "$status" -eq 0 ]
    [[ "$output" == *"Neustart empfohlen (neuerer Kernel 999.0.1-1.fc99.x86_64 installiert, es läuft noch $(uname -r))"* ]]
    not_called "needs-restarting"
}

@test "älterer installierter Kernel ist kein Grund für einen Neustart" {
    export MOCK_KERNEL="0.0.1-1.fc99.x86_64"
    run_script
    [ "$status" -eq 0 ]
    [[ "$output" != *"neuerer Kernel"* ]]
    called "sudo env LC_ALL=C dnf needs-restarting -r"
    [[ "$output" == *"Kein Neustart erforderlich"* ]]
}

@test "laufender Kernel ist aktuell, needs-restarting entscheidet" {
    MOCK_KERNEL="$(uname -r)"
    export MOCK_KERNEL
    run_script
    [ "$status" -eq 0 ]
    called "sudo env LC_ALL=C dnf needs-restarting -r"
    [[ "$output" == *"Kein Neustart erforderlich"* ]]
}

@test "needs-restarting meldet nötigen Neustart (Code 1 mit Hinweistext)" {
    export MOCK_NEEDS_RESTARTING_RC=1
    export MOCK_NEEDS_RESTARTING_OUTPUT="Reboot is required to fully utilize these updates."
    run_script
    [ "$status" -eq 0 ]
    [[ "$output" == *"Neustart empfohlen (Systemkomponenten aktualisiert)"* ]]
}

@test "needs-restarting-Hinweistext wird unabhängig von Groß-/Kleinschreibung erkannt" {
    export MOCK_NEEDS_RESTARTING_RC=1
    export MOCK_NEEDS_RESTARTING_OUTPUT="REBOOT IS REQUIRED to fully utilize these updates."
    run_script
    [ "$status" -eq 0 ]
    [[ "$output" == *"Neustart empfohlen (Systemkomponenten aktualisiert)"* ]]
}

@test "needs-restarting mit Code 1, aber Fehlermeldung, gilt als unklar" {
    export MOCK_NEEDS_RESTARTING_RC=1
    export MOCK_NEEDS_RESTARTING_OUTPUT="No such command: needs-restarting."
    run_script
    [ "$status" -eq 0 ]
    [[ "$output" == *"Neustartstatus unklar"* ]]
    [[ "$output" == *"No such command"* ]]
}

@test "needs-restarting mit anderem Code meldet unklaren Status" {
    export MOCK_NEEDS_RESTARTING_RC=2
    run_script
    [ "$status" -eq 0 ]
    [[ "$output" == *"Neustartstatus unklar"* ]]
}
