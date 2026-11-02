#!/bin/bash
# Strikte Fehlerbehandlung:
# -E: Vererbt ERR-Traps an Subshells und Funktionen
# -e: Bricht bei Fehlern ab
# -u: Bricht bei undefinierten Variablen ab
# -o pipefail: Bricht ab, wenn ein Befehl innerhalb einer Pipeline fehlschlägt
set -Eeuo pipefail

# =========================================================
# KONFIGURATION
# =========================================================

RUN_AUTOREMOVE="false"
RUN_SNAP_UPDATE="false"
RUN_FIRMWARE_UPDATE="false"
DRY_RUN="false"
ASSUME_YES="false"
LOGFILE=""

# Pakete, deren Teil-Update (DNF überspringt sie, aktualisiert aber den Rest) das System unbrauchbar machen kann,
# z.B. libplasma ohne den Rest von Plasma. Werden solche Pakete übersprungen, fragt das Skript vor dem Update nach.
# Muster wie bei Bash-Globs ('*' = beliebige Zeichen), verglichen mit dem Paketnamen.
CRITICAL_PACKAGES=(
    'kernel*' 'glibc*' 'systemd*' 'dnf*' 'libdnf*' 'rpm' 'rpm-*' 'grub2*' 'shim*' 'dracut*' 'linux-firmware*'
    'selinux-policy*' 'mesa-*' 'NetworkManager*' 'pipewire*' 'wireplumber*' 'xorg-x11-server*' 'xwayland*'
    'plasma-*' 'libplasma*' 'kf6-*' 'kwin*' 'sddm*' 'qt6-*' 'gnome-shell*' 'mutter*' 'gdm*' 'gtk4*' 'glib2*'
)

# =========================================================
# FUNKTIONEN & INITIALISIERUNG
# =========================================================

# Farben und NO_COLOR Unterstützung
if [[ -t 1 && -z "${NO_COLOR:-}" ]]; then
    GREEN=$'\033[1;32m'
    BLUE=$'\033[1;34m'
    YELLOW=$'\033[1;33m'
    RED=$'\033[1;31m'
    RESET=$'\033[0m'
else
    GREEN=""
    BLUE=""
    YELLOW=""
    RED=""
    RESET=""
fi

# Ausgabefunktionen für sauberen Code
info()    { printf '%b▶ %s%b\n' "$BLUE" "$*" "$RESET"; }
success() { printf '%b✔ %s%b\n' "$GREEN" "$*" "$RESET"; }
warning() { printf '%b⚠ %s%b\n' "$YELLOW" "$*" "$RESET"; }
error()   { printf '%b❌ %s%b\n' "$RED" "$*" "$RESET" >&2; }

# Führt einen Befehl aus, oder zeigt ihn im Dry-Run-Modus nur an
run_step() {
    if [[ "$DRY_RUN" == "true" ]]; then
        info "[DRY-RUN] Würde ausführen: $*"
        return 0
    fi
    "$@"
}

print_usage() {
    cat <<EOF
Verwendung: ${0##*/} [OPTIONEN]

Aktualisiert ein Fedora-System (DNF, Flatpak, optional Snap und Firmware)
in einem abgesicherten Durchlauf.

Optionen:
  --autoremove     Entfernt nicht mehr benötigte Pakete ('dnf autoremove')
                   und ungenutzte Flatpak-Laufzeitumgebungen.
  --snap           Aktiviert Snap-Updates (falls installiert und aktiv).
  --firmware       Spielt Firmware-Updates über fwupd ein (falls installiert).
                   Ein dafür nötiger Neustart erfolgt nicht automatisch.
  --yes            Beantwortet die Rückfrage bei kritischen Befunden der
                   DNF-Vorabprüfung (Teil-Update von Kernpaketen, Entfernen
                   oder Herabstufen von Paketen, Fehler) mit Ja. Ohne diese
                   Option wird das DNF-Update in solchen Fällen ohne Terminal
                   (z.B. per Cron) übersprungen.
  --log <Datei>    Schreibt die komplette Ausgabe zusätzlich in <Datei>
                   (Farben werden dabei deaktiviert).
  --dry-run        Zeigt nur an, welche Befehle ausgeführt würden, ohne
                   Änderungen am System vorzunehmen. Es werden dabei keine
                   Administratorrechte angefordert; der detaillierte
                   Neustart-Check am Ende entfällt daher.
  -h, --help       Zeigt diese Hilfe an und beendet das Skript.

Exit-Codes:
  0                Alle Schritte erfolgreich (bzw. Dry-Run abgeschlossen).
  1                Ungültiger Aufruf, ungeeignete Umgebung (kein Fedora,
                   Start als root) oder Teilfehler (von DNF übersprungene
                   Pakete, nach kritischen Befunden nicht ausgeführtes
                   DNF-Update, Flatpak/Snap/Firmware).
  sonstige         Abbruch durch einen fehlgeschlagenen Befehl.
EOF
}

# =========================================================
# KOMMANDOZEILEN-PARAMETER
# =========================================================

while [[ "$#" -gt 0 ]]; do
    case $1 in
        --autoremove) RUN_AUTOREMOVE="true" ;;
        --snap) RUN_SNAP_UPDATE="true" ;;
        --firmware) RUN_FIRMWARE_UPDATE="true" ;;
        --dry-run) DRY_RUN="true" ;;
        --yes) ASSUME_YES="true" ;;
        -h|--help)
            print_usage
            exit 0
            ;;
        --log)
            if [[ "$#" -lt 2 ]]; then
                error "Fehlendes Argument für --log <Dateipfad>"
                exit 1
            fi
            LOGFILE="$2"
            shift
            ;;
        *)
            error "Unbekannter Parameter: $1 (Hilfe mit --help)"
            exit 1
            ;;
    esac
    shift
done

# Keine ANSI-Farbcodes in die Logdatei schreiben
if [[ -n "$LOGFILE" ]]; then
    GREEN="" BLUE="" YELLOW="" RED="" RESET=""
fi

# DNF färbt seine Ausgabe nur, wenn es direkt ins Terminal schreibt. Das Skript liest die Ausgabe aber mit
# (Pipe bzw. Datei), daher werden die Farben ausdrücklich angefordert, sofern das Skript selbst Farben nutzt
# (Terminal, kein NO_COLOR, kein --log). Die Auswertung entfernt die Farbcodes vorher (siehe strip_ansi).
DNF_COLOR_OPTS=()
[[ -n "$GREEN" ]] && DNF_COLOR_OPTS=(--color=always)

# =========================================================
# SYSTEMPRÜFUNGEN
# =========================================================

# Betriebssystem-Prüfung
if [[ ! -r /etc/fedora-release ]]; then
    error "Dieses Skript ist ausschließlich für Fedora vorgesehen."
    exit 1
fi

# Root-Check (vor dem Logging, damit keine root-eigene Logdatei entsteht)
if [[ "${EUID:-}" -eq 0 ]]; then
    error "Bitte das Skript NICHT als Root (mit sudo) starten! Das Skript fordert die Rechte selbst an."
    exit 1
fi

# Abhängigkeiten prüfen
required_commands=(sudo dnf rpm uname sort date tee mktemp rm)
for cmd in "${required_commands[@]}"; do
    if ! command -v "$cmd" &>/dev/null; then
        error "Erforderlicher Befehl fehlt: $cmd"
        exit 127
    fi
done

# Logging einrichten, falls Parameter übergeben wurde
if [[ -n "$LOGFILE" ]]; then
    if ! touch "$LOGFILE" 2>/dev/null; then
        error "Kann nicht in Logdatei schreiben: $LOGFILE"
        exit 1
    fi
    # Leitet stdout und stderr in die Logdatei UND auf das Terminal um
    exec > >(tee -a "$LOGFILE") 2>&1
fi

# Traps für Fehler und sauberes Beenden
# shellcheck disable=SC2154  # err_code wird im Trap-String selbst gesetzt
trap 'err_code=$?; error "Fehler in Zeile $LINENO (Code $err_code): $BASH_COMMAND"; error "Update abgebrochen."; exit $err_code' ERR

# shellcheck disable=SC2317,SC2329  # wird indirekt über 'trap cleanup EXIT' aufgerufen
cleanup() {
    if [[ -n "${SUDO_KEEPALIVE_PID:-}" ]]; then
        kill "$SUDO_KEEPALIVE_PID" 2>/dev/null || true
        wait "$SUDO_KEEPALIVE_PID" 2>/dev/null || true
    fi
    if [[ -n "${FLATPAK_OUTPUT_FILE:-}" ]]; then
        rm -f "$FLATPAK_OUTPUT_FILE"
    fi
    if [[ -n "${DNF_OUTPUT_FILE:-}" ]]; then
        rm -f "$DNF_OUTPUT_FILE"
    fi
    if [[ -n "${DNF_PREVIEW_FILE:-}" ]]; then
        rm -f "$DNF_PREVIEW_FILE"
    fi
}
trap cleanup EXIT

# ---------------------------------------------------------
# HAUPTSKRIPT
# ---------------------------------------------------------

UPDATE_WARNINGS=()

info "Start: $(date '+%d.%m.%Y %H:%M:%S')"
[[ -n "$LOGFILE" ]] && info "Logging in Datei aktiv: $LOGFILE"
[[ "$DRY_RUN" == "true" ]] && warning "Dry-Run-Modus aktiv: Es werden keine Änderungen am System vorgenommen."

if [[ "$DRY_RUN" == "true" ]]; then
    info "Fordere keine Administratorrechte an (Dry-Run-Modus)."
else
    info "Fordere Administratorrechte an..."
    sudo -v

    # Sudo-Ticket im Hintergrund alle 50s erneuern. Die Umleitung nach /dev/null verhindert,
    # dass ein noch laufendes 'sleep' nach Skriptende eine Ausgabe-Pipe (z.B. '| tee') offen hält.
    ( while kill -0 $$ 2>/dev/null; do sudo -n -v 2>/dev/null || true; sleep 50; done ) </dev/null >/dev/null 2>&1 &
    SUDO_KEEPALIVE_PID=$!
fi

# Wertet die Ausgabe von 'dnf upgrade' aus: Welche Updates hat DNF wegen Konflikten oder nicht auflösbarer
# Abhängigkeiten übersprungen, und welche installierten Pakete verursachen das? dnf5 meldet so etwas nur als
# Tabelle ("Pakete mit Konflikten werden übersprungen:") und endet trotzdem mit Code 0.
# Erkannt werden die deutschen und englischen Texte von dnf5 (bzw. dnf4: "Skipping packages ...").
# - DNF_SKIPPED: Namen der übersprungenen Pakete (ohne die Verursacher selbst)
# - DNF_BLOCKERS: installierte Pakete, die eine alte Version voraussetzen ("installiertes Paket X benötigt ..."),
#   jeweils mit der Paketquelle, aus der sie stammen (falls DNF sie nennt), z.B. "foo (copr:...)"
# Aufruf: collect_dnf_skipped <Datei mit der DNF-Ausgabe>
# Entfernt ANSI-Steuersequenzen (Farben, Fett) aus einer Zeile: strip_ansi <Variablenname>
strip_ansi() {
    local -n _strip_line=$1
    local ansi_re=$'\e''\[[0-9;]*[A-Za-z]'
    while [[ "$_strip_line" =~ $ansi_re ]]; do
        _strip_line=${_strip_line/"${BASH_REMATCH[0]}"/}
    done
}

DNF_SKIPPED=()
DNF_BLOCKERS=()
collect_dnf_skipped() {
    local file=$1 line name in_table="false"
    local -a skipped=() blockers=()
    local -A seen=() blocker_seen=() blocker_repo=()
    local blocker_re='(installiertes Paket|installed package) ([^[:space:]]+) (benötigt|requires) '
    local repo_re='(Paket|package) ([^[:space:]]+) (aus|from) ([^[:space:]]+) (benötigt|requires) '
    local header_re='(übersprungen|[Ss]kipping[^:]*):[[:space:]]*$'
    local row_re='^[[:space:]]+([^[:space:]]+)[[:space:]]+[^[:space:]]+[[:space:]]+[^[:space:]]+[[:space:]]+[^[:space:]]+'

    # Paketname aus "name-version-release.arch" (die Architektur hängt am Release)
    pkg_name() { local n=${1%-*}; printf '%s' "${n%-*}"; }

    while IFS= read -r line || [[ -n "$line" ]]; do
        strip_ansi line
        if [[ "$line" =~ $blocker_re ]]; then
            name=$(pkg_name "${BASH_REMATCH[2]}")
            [[ -n "${blocker_seen[$name]:-}" ]] || { blocker_seen[$name]=1; blockers+=("$name"); }
        fi
        if [[ "$line" =~ $repo_re && "${BASH_REMATCH[4]}" != @* ]]; then
            name=$(pkg_name "${BASH_REMATCH[2]}")
            [[ -n "${blocker_repo[$name]:-}" ]] || blocker_repo[$name]=${BASH_REMATCH[4]}
        fi
        if [[ "$line" =~ $header_re ]]; then
            in_table="true"
        elif [[ "$in_table" == "true" && "$line" =~ ^[[:space:]]*\( ]]; then
            # dnf4 schreibt unter die Überschrift noch "(add '--best --allowerasing' ...)"
            continue
        elif [[ "$in_table" == "true" && "$line" =~ $row_re ]]; then
            name=${BASH_REMATCH[1]}
            [[ -n "${seen[$name]:-}" ]] || { seen[$name]=1; skipped+=("$name"); }
        else
            in_table="false"
        fi
    done < "$file"

    DNF_SKIPPED=()
    DNF_BLOCKERS=()
    for name in "${skipped[@]}"; do
        [[ -n "${blocker_seen[$name]:-}" ]] || DNF_SKIPPED+=("$name")
    done
    for name in "${blockers[@]}"; do
        if [[ -n "${blocker_repo[$name]:-}" ]]; then
            DNF_BLOCKERS+=("$name (${blocker_repo[$name]})")
        else
            DNF_BLOCKERS+=("$name")
        fi
    done
    # Falls nur Verursacher in der Tabelle standen, sind sie selbst das übersprungene Update
    if [[ ${#DNF_SKIPPED[@]} -eq 0 && ${#skipped[@]} -gt 0 ]]; then
        DNF_SKIPPED=("${skipped[@]}")
    fi
}

# Verbindet die Argumente zu "a, b, c"
join_list() {
    local out
    out=$(IFS=$'\x1f'; printf '%s' "$*")
    printf '%s' "${out//$'\x1f'/, }"
}

# Liest die Sektionen "Removing:", "Removing dependent packages:" und "Downgrading:" aus der (englischen)
# Transaktionsübersicht von dnf5/dnf4. Aufruf: collect_dnf_section_packages <Datei> <remove|downgrade>
collect_dnf_section_packages() {
    local file=$1 kind=$2 line in_section="false"
    local -A seen=()
    local remove_re='^(Removing|Removing dependent packages):[[:space:]]*$'
    local downgrade_re='^Downgrading:[[:space:]]*$'
    local row_re='^[[:space:]]+([^[:space:]]+)[[:space:]]+[^[:space:]]+[[:space:]]+[^[:space:]]+'
    local header_re
    if [[ "$kind" == "remove" ]]; then header_re=$remove_re; else header_re=$downgrade_re; fi
    while IFS= read -r line || [[ -n "$line" ]]; do
        strip_ansi line
        if [[ "$line" =~ $header_re ]]; then
            in_section="true"
        elif [[ "$in_section" == "true" && "$line" =~ $row_re ]]; then
            # Unterzeilen wie "   replacing foo ..." gehören zum Paket darüber
            [[ "${BASH_REMATCH[1]}" == "replacing" ]] && continue
            [[ -n "${seen[${BASH_REMATCH[1]}]:-}" ]] || { seen[${BASH_REMATCH[1]}]=1; printf '%s\n' "${BASH_REMATCH[1]}"; }
        else
            in_section="false"
        fi
    done < "$file"
}

# Prüft, ob ein Paketname zu einem Muster aus CRITICAL_PACKAGES passt
is_critical_package() {
    local pattern
    for pattern in "${CRITICAL_PACKAGES[@]}"; do
        # shellcheck disable=SC2053  # das Muster soll als Glob wirken
        [[ "$1" == $pattern ]] && return 0
    done
    return 1
}

# Vorabprüfung: Spielt die Transaktion mit '--assumeno' durch (DNF löst alles auf, ändert aber nichts) und
# sammelt kritische Befunde in DNF_CRITICAL. Die Ausgabe wird auf Englisch erzeugt (LC_ALL=C), damit die
# Auswertung nicht von der Sprache abhängt.
DNF_CRITICAL=()
DNF_PREVIEW_FILE=""
dnf_preflight() {
    local rc=0 name preview
    local -a critical_skipped=() removed=() downgraded=()
    DNF_PREVIEW_FILE=$(mktemp)
    run_step sudo env LC_ALL=C dnf upgrade --refresh --assumeno "${DNF_COLOR_OPTS[@]}" > "$DNF_PREVIEW_FILE" 2>&1 || rc=$?
    [[ "$DRY_RUN" == "true" ]] && cat "$DNF_PREVIEW_FILE"

    collect_dnf_skipped "$DNF_PREVIEW_FILE"
    for name in "${DNF_SKIPPED[@]}"; do
        is_critical_package "$name" && critical_skipped+=("$name")
    done
    mapfile -t removed < <(collect_dnf_section_packages "$DNF_PREVIEW_FILE" remove)
    mapfile -t downgraded < <(collect_dnf_section_packages "$DNF_PREVIEW_FILE" downgrade)

    if [[ ${#critical_skipped[@]} -gt 0 ]]; then
        local msg
        msg="Teil-Update von Kernpaketen: DNF würde diese Updates überspringen, den Rest aber einspielen: $(join_list "${critical_skipped[@]}")."
        if [[ ${#DNF_BLOCKERS[@]} -gt 0 ]]; then
            msg+=" Ursache: $(join_list "${DNF_BLOCKERS[@]}"). Abhilfe: dieses Paket entfernen ('sudo dnf remove <Paket>') und das Skript erneut starten, oder auf ein passendes Update warten."
        fi
        DNF_CRITICAL+=("$msg")
    fi
    if [[ ${#removed[@]} -gt 0 ]]; then
        DNF_CRITICAL+=("DNF würde Pakete entfernen: $(join_list "${removed[@]}").")
    fi
    if [[ ${#downgraded[@]} -gt 0 ]]; then
        DNF_CRITICAL+=("DNF würde Pakete auf eine ältere Version herabstufen: $(join_list "${downgraded[@]}").")
    fi
    # '--assumeno' bricht eine anstehende Transaktion mit Code 1 ab ("Operation aborted"); das ist kein Fehler
    preview=$(<"$DNF_PREVIEW_FILE")
    strip_ansi preview
    if (( rc != 0 )) && [[ "${preview,,}" != *"operation aborted"* ]]; then
        DNF_CRITICAL+=("Die Vorabprüfung von DNF ist fehlgeschlagen (Code $rc), siehe Ausgabe oben.")
    fi
}

# Fragt nach, ob trotz kritischer Befunde aktualisiert werden soll. Rückgabe 0 = fortfahren.
confirm_dnf_upgrade() {
    local finding answer
    printf '\n'
    warning "Die Vorabprüfung von DNF hat kritische Punkte gefunden. Ein Update in diesem Zustand kann das System beschädigen (z.B. Desktop startet nicht mehr)."
    for finding in "${DNF_CRITICAL[@]}"; do
        printf '%b  • %s%b\n' "$YELLOW" "$finding" "$RESET"
    done
    if [[ "$ASSUME_YES" == "true" ]]; then
        warning "Fahre trotzdem fort (--yes)."
        return 0
    fi
    if [[ ! -t 0 ]]; then
        error "Keine Rückfrage möglich (keine interaktive Eingabe). Das DNF-Update wird übersprungen; mit --yes würde es trotzdem ausgeführt."
        return 1
    fi
    read -r -p "Trotzdem mit dem DNF-Update fortfahren? [j/N] " answer || answer=""
    case "${answer,,}" in
        j|ja|y|yes) return 0 ;;
    esac
    warning "DNF-Update auf Wunsch übersprungen."
    return 1
}

printf '\n'
info "Prüfe die anstehende DNF-Transaktion (Vorabprüfung ohne Änderungen, lädt ggf. Paketquellen neu)..."
dnf_preflight
DNF_UPGRADE_SKIPPED="false"
if [[ ${#DNF_CRITICAL[@]} -gt 0 ]]; then
    # Die Vorschau von DNF zeigen, damit die Befunde nachvollziehbar sind
    cat "$DNF_PREVIEW_FILE"
    if ! confirm_dnf_upgrade; then
        DNF_UPGRADE_SKIPPED="true"
        UPDATE_WARNINGS+=("DNF-Update nicht ausgeführt")
    fi
else
    success "Vorabprüfung ohne kritische Befunde."
fi
DNF_SKIPPED=()
DNF_BLOCKERS=()

if [[ "$DNF_UPGRADE_SKIPPED" != "true" ]]; then
    printf '\n'
    info "Starte System-Updates via DNF..."
    DNF_OUTPUT_FILE=$(mktemp)
    # Die Ausgabe wird zusätzlich gesammelt, um übersprungene Pakete am Ende zusammenzufassen.
    # '--refresh' entfällt, die Paketquellen hat die Vorabprüfung gerade geladen.
    run_step sudo dnf upgrade -y "${DNF_COLOR_OPTS[@]}" 2>&1 | tee "$DNF_OUTPUT_FILE"
    collect_dnf_skipped "$DNF_OUTPUT_FILE"
    if [[ ${#DNF_SKIPPED[@]} -gt 0 ]]; then
        UPDATE_WARNINGS+=("DNF-Konflikte")
    fi
fi

if [[ "$DNF_UPGRADE_SKIPPED" == "true" ]]; then
    info "DNF 'autoremove' entfällt, weil das DNF-Update nicht ausgeführt wurde."
elif [[ "$RUN_AUTOREMOVE" == "true" ]]; then
    printf '\n'
    info "Führe DNF Autoremove aus..."
    run_step sudo dnf autoremove -y
else
    info "DNF 'autoremove' ist nicht aktiviert (nutze --autoremove). Übersprungen."
fi

# Ergänzt die Fortschrittszeilen von flatpak ("Aktualisiere 9/16 …") um die ID des gerade bearbeiteten Eintrags.
# flatpak gibt vor dem Start eine nummerierte Tabelle aus (" 9.     org.example.App  stable  u  flathub  < 12 MB");
# die Nummer in der Fortschrittszeile verweist auf diese Tabellenzeile. Alle übrigen Zeilen bleiben unverändert.
# Das Muster hängt nur an "<Nummer>/<Anzahl> …", nicht am (übersetzten) Text davor.
flatpak_annotate() {
    local line
    local -A ids=()
    local row_re='^[[:space:]]*([0-9]+)\.[[:space:]]+([^[:space:]]+)'
    local progress_re='^(.*[^0-9])([0-9]+)/([0-9]+)( ?…)(.*)$'
    while IFS= read -r line || [[ -n "$line" ]]; do
        if [[ "$line" =~ $row_re ]]; then
            ids[${BASH_REMATCH[1]}]=${BASH_REMATCH[2]}
        elif [[ "$line" =~ $progress_re ]] && [[ -n "${ids[${BASH_REMATCH[2]}]:-}" ]]; then
            line="${BASH_REMATCH[1]}${BASH_REMATCH[2]}/${BASH_REMATCH[3]} ${ids[${BASH_REMATCH[2]}]}${BASH_REMATCH[4]}${BASH_REMATCH[5]}"
        fi
        printf '%s\n' "$line"
    done
}

# Führt einen flatpak-Befehl für eine Installation ('system' oder 'user') aus: flatpak_step <scope> <befehl> [args...]
# Die Ausgabe erscheint wie gewohnt (Fortschrittszeilen ergänzt um die Flatpak-ID, siehe flatpak_annotate) und wird
# zusätzlich in FLATPAK_OUTPUT_FILE gesammelt (für den EOL-Hinweis).
# - FLATPAK_FANCY_OUTPUT=0 schaltet die sich ständig neu zeichnende Fortschrittstabelle ab, die bei vielen
#   Updates oder schmalem Terminal zu unlesbaren Zeilen führt.
# - Die systemweite Installation läuft über sudo. Ohne Rechte entscheidet polkit, und das verweigert z.B.
#   ohne aktive lokale Sitzung "Deploy"/"GetRevokefsFd" ("not allowed for user").
# - FLATPAK_USER_DIR zeigt dabei auf die Benutzerinstallation des Aufrufers. flatpak berücksichtigt so beim
#   Aufräumen weiterhin Benutzer-Apps, die Laufzeitumgebungen der Systeminstallation nutzen (sonst sähe es nur
#   die Benutzerinstallation von root).
# - XDG_DATA_DIRS geht über sudo sonst verloren. Dann meldet update-mime-database (von flatpak nach dem Update
#   aufgerufen), '/var/lib/flatpak/exports/share' liege nicht im Suchpfad. Daher wird der Wert des Aufrufers
#   weitergegeben, bei Bedarf um dieses Verzeichnis ergänzt.
flatpak_step() {
    local scope=$1 cmd=$2
    shift 2
    if [[ "$scope" == "system" ]]; then
        run_step sudo env FLATPAK_FANCY_OUTPUT=0 FLATPAK_USER_DIR="$FLATPAK_USER_DIR" XDG_DATA_DIRS="$FLATPAK_XDG_DATA_DIRS" \
            flatpak "$cmd" --system "$@" 2>&1 | flatpak_annotate | tee -a "$FLATPAK_OUTPUT_FILE"
    else
        run_step env FLATPAK_FANCY_OUTPUT=0 flatpak "$cmd" --user "$@" 2>&1 | flatpak_annotate | tee -a "$FLATPAK_OUTPUT_FILE"
    fi
}

# Sammelt aus der flatpak-Ausgabe veraltete (end-of-life) Laufzeitumgebungen und die Apps, die sie noch nutzen.
# Diese werden bewusst nicht entfernt; das Skript weist am Ende nur darauf hin.
FLATPAK_EOL_RUNTIMES=()
FLATPAK_EOL_APPS=()
collect_flatpak_eol() {
    local line entry in_apps="false"
    local -A seen=()
    while IFS= read -r line; do
        if [[ "$line" =~ runtime\ ([^[:space:]]+)\ branch\ ([^[:space:]]+)\ is\ end-of-life ]]; then
            entry="${BASH_REMATCH[1]}//${BASH_REMATCH[2]}"
            [[ -n "${seen[$entry]:-}" ]] || { seen[$entry]=1; FLATPAK_EOL_RUNTIMES+=("$entry"); }
            in_apps="false"
        elif [[ "$line" == *"using this runtime:"* || "$line" == *"using this extension:"* ]]; then
            in_apps="true"
        elif [[ "$in_apps" == "true" && "$line" =~ ^[[:space:]]+([^[:space:]]+)[[:space:]]*$ ]]; then
            entry="${BASH_REMATCH[1]}"
            [[ -n "${seen[$entry]:-}" ]] || { seen[$entry]=1; FLATPAK_EOL_APPS+=("$entry"); }
        else
            in_apps="false"
        fi
    done < "$FLATPAK_OUTPUT_FILE"
}

printf '\n'
info "Starte Flatpak-Updates..."
if command -v flatpak &>/dev/null; then
    FLATPAK_USER_DIR="${XDG_DATA_HOME:-$HOME/.local/share}/flatpak"
    FLATPAK_XDG_DATA_DIRS="${XDG_DATA_DIRS:-/usr/local/share:/usr/share}"
    if [[ ":$FLATPAK_XDG_DATA_DIRS:" != *":/var/lib/flatpak/exports/share:"* \
        && ":$FLATPAK_XDG_DATA_DIRS:" != *":/var/lib/flatpak/exports/share/:"* ]]; then
        FLATPAK_XDG_DATA_DIRS="/var/lib/flatpak/exports/share:$FLATPAK_XDG_DATA_DIRS"
    fi
    FLATPAK_OUTPUT_FILE=$(mktemp)
    # Die Benutzerinstallation nur anfassen, wenn dort etwas installiert ist
    FLATPAK_SCOPES=(system)
    if [[ -n "$(flatpak list --user --columns=ref 2>/dev/null || true)" ]]; then
        FLATPAK_SCOPES+=(user)
    fi

    # Das '||' verhindert, dass set -e das Skript bei temporären Flatpak-Fehlern beendet
    for scope in "${FLATPAK_SCOPES[@]}"; do
        flatpak_step "$scope" update -y || {
            warning "Flatpak-Update ($scope) meldete einen Fehler (z.B. Repo unerreichbar)."
            [[ " ${UPDATE_WARNINGS[*]} " == *" Flatpak "* ]] || UPDATE_WARNINGS+=("Flatpak")
        }
    done
    if [[ "$RUN_AUTOREMOVE" == "true" ]]; then
        info "Entferne ungenutzte Flatpak-Laufzeitumgebungen..."
        # 'uninstall --unused' entfernt nur, was keine installierte App mehr braucht (auch keine EOL-Laufzeitumgebungen in Benutzung)
        for scope in "${FLATPAK_SCOPES[@]}"; do
            flatpak_step "$scope" uninstall --unused -y || {
                warning "Entfernen ungenutzter Flatpak-Laufzeitumgebungen ($scope) meldete einen Fehler."
                [[ " ${UPDATE_WARNINGS[*]} " == *" Flatpak-Aufräumen "* ]] || UPDATE_WARNINGS+=("Flatpak-Aufräumen")
            }
        done
    fi
    collect_flatpak_eol
else
    info "Flatpak ist nicht installiert. Übersprungen."
fi

printf '\n'
if [[ "$RUN_SNAP_UPDATE" == "true" ]]; then
    info "Starte Snap-Updates..."
    if command -v snap &>/dev/null; then
        if systemctl is-active --quiet snapd.service || systemctl is-active --quiet snapd.socket; then
            run_step sudo snap refresh || {
                warning "Snap-Update meldete einen Fehler."
                UPDATE_WARNINGS+=("Snap")
            }
        else
            warning "Snap ist zwar installiert, aber der snapd-Dienst ist nicht aktiv. Übersprungen."
        fi
    else
        info "Snap ist nicht installiert. Übersprungen."
    fi
else
    info "Snap-Updates sind nicht aktiviert (nutze --snap). Übersprungen."
fi

printf '\n'
FIRMWARE_UPDATED="false"
if [[ "$RUN_FIRMWARE_UPDATE" == "true" ]]; then
    info "Starte Firmware-Updates via fwupd..."
    if command -v fwupdmgr &>/dev/null; then
        # fwupdmgr meldet Exit-Code 2, wenn es nichts zu tun gibt
        fw_rc=0
        run_step sudo fwupdmgr refresh || fw_rc=$?
        if (( fw_rc == 0 || fw_rc == 2 )); then
            fw_rc=0
            # 'update' endet auch mit 0, wenn nichts installiert wurde. Daher vorher fragen, ob Updates anstehen.
            run_step sudo fwupdmgr get-updates --no-unreported-check || fw_rc=$?
        fi
        if (( fw_rc == 0 )); then
            # --no-reboot-check: sonst startet '-y' den Rechner sofort neu, falls ein Update das verlangt
            run_step sudo fwupdmgr update -y --no-reboot-check --no-unreported-check || fw_rc=$?
        fi
        if (( fw_rc == 2 )); then
            info "Keine Firmware-Updates verfügbar."
        elif (( fw_rc != 0 )); then
            warning "Firmware-Update meldete einen Fehler (Code $fw_rc)."
            UPDATE_WARNINGS+=("Firmware")
        elif [[ "$DRY_RUN" != "true" ]]; then
            # Eingespielte Updates, auch solche, die auf einen Neustart warten, listet 'get-updates' nicht mehr.
            # Geräte, die eine Benutzeraktion brauchen (z.B. Netzteil anschließen), stehen dagegen noch drin.
            if sudo fwupdmgr get-updates --no-unreported-check >/dev/null 2>&1; then
                warning "Nicht alle Firmware-Updates wurden eingespielt (z.B. weil ein Netzteil angeschlossen sein muss). Details stehen oben in der Ausgabe von fwupd."
                UPDATE_WARNINGS+=("Firmware")
            else
                FIRMWARE_UPDATED="true"
            fi
        fi
    else
        info "fwupd ist nicht installiert. Übersprungen."
    fi
else
    info "Firmware-Updates sind nicht aktiviert (nutze --firmware). Übersprungen."
fi

printf '\n'
info "Prüfe Systemstatus..."

# Sichere Kernel-Prüfung
CURRENT_KERNEL=$(uname -r)
LATEST_KERNEL=""
if rpm -q kernel-core &>/dev/null; then
    LATEST_KERNEL=$(LC_ALL=C rpm -q kernel-core --queryformat '%{VERSION}-%{RELEASE}.%{ARCH}\n' | sort -V | tail -n 1 || true)
fi

# Nur ein installierter Kernel, der NEUER als der laufende ist, erfordert einen Neustart. Ein älterer
# (z.B. weil ein selbst gebauter oder Test-Kernel läuft) ist kein Grund dafür.
KERNEL_PENDING="false"
if [[ -n "$LATEST_KERNEL" && "$CURRENT_KERNEL" != "$LATEST_KERNEL" ]] \
    && [[ "$(printf '%s\n' "$CURRENT_KERNEL" "$LATEST_KERNEL" | sort -V | tail -n 1)" == "$LATEST_KERNEL" ]]; then
    KERNEL_PENDING="true"
fi

# Neustart-Logik mit exakter Return-Code-Auswertung
if [[ "$KERNEL_PENDING" == "true" ]]; then
    # Der neuere Kernel kann auch aus einem früheren Update stammen, nach dem noch nicht neu gestartet wurde
    REBOOT_MSG="System-Neustart empfohlen (neuerer Kernel $LATEST_KERNEL installiert, es läuft noch $CURRENT_KERNEL)."
    REBOOT_COLOR="$YELLOW"
    REBOOT_ICON="⚠"
elif [[ "$DRY_RUN" == "true" ]]; then
    REBOOT_MSG="Genauer Neustart-Status im Dry-Run nicht geprüft (erfordert Root-Rechte)."
    REBOOT_COLOR="$BLUE"
    REBOOT_ICON="ℹ"
elif [[ "$FIRMWARE_UPDATED" == "true" ]]; then
    REBOOT_MSG="System-Neustart empfohlen (Firmware aktualisiert; manche Updates werden erst beim Neustart eingespielt)."
    REBOOT_COLOR="$YELLOW"
    REBOOT_ICON="⚠"
elif NEEDS_RESTART_OUTPUT=$(sudo env LC_ALL=C dnf needs-restarting -r 2>&1); then
    REBOOT_MSG="Kein Neustart erforderlich."
    REBOOT_COLOR="$GREEN"
    REBOOT_ICON="✔"
else
    NEEDS_RESTART_RC=$?
    # Code 1 bedeutet "Neustart nötig", aber auch allgemeine Fehler (z.B. fehlendes Plugin unter dnf4)
    # enden mit 1. Daher zusätzlich den Ausgabetext prüfen; LC_ALL=C sorgt für englische Ausgabe.
    # Groß-/Kleinschreibung wird ignoriert, damit eine geänderte Schreibweise in dnf5 nicht stört.
    if (( NEEDS_RESTART_RC == 1 )) && [[ "${NEEDS_RESTART_OUTPUT,,}" == *"reboot is required"* ]]; then
        # needs-restarting vergleicht mit dem Systemstart, nicht mit diesem Lauf: Die Komponenten können auch
        # bei einem früheren Update aktualisiert worden sein. Die aufgelisteten Pakete ("  * kernel") nennen.
        restart_pkgs=()
        while IFS= read -r line; do
            [[ "$line" =~ ^[[:space:]]*\*[[:space:]]+([^[:space:]]+) ]] && restart_pkgs+=("${BASH_REMATCH[1]}")
        done <<< "$NEEDS_RESTART_OUTPUT"
        if [[ ${#restart_pkgs[@]} -gt 0 ]]; then
            REBOOT_MSG="System-Neustart empfohlen (seit dem letzten Systemstart aktualisiert: $(join_list "${restart_pkgs[@]}"))."
        else
            REBOOT_MSG="System-Neustart empfohlen (Systemkomponenten wurden seit dem letzten Systemstart aktualisiert)."
        fi
        REBOOT_COLOR="$YELLOW"
        REBOOT_ICON="⚠"
    else
        REBOOT_MSG="Neustartstatus unklar (fehlt evtl. das needs-restarting-Plugin: 'dnf5-plugins' bzw. bei dnf4 'python3-dnf-plugins-core'?)"
        REBOOT_COLOR="$RED"
        REBOOT_ICON="❓"
        warning "DNF-Prüfung fehlgeschlagen (Code $NEEDS_RESTART_RC): $NEEDS_RESTART_OUTPUT"
    fi
fi

# Finale Ausgabe im Terminal
printf '\n'
EXIT_CODE=0
if [[ "$DRY_RUN" == "true" ]]; then
    success "Dry-Run abgeschlossen. Es wurden keine Änderungen am System vorgenommen. ($(date '+%H:%M:%S'))"
elif [[ ${#UPDATE_WARNINGS[@]} -eq 0 ]]; then
    success "Alle vorgesehenen Update-Schritte wurden ohne Fehler ausgeführt. ($(date '+%H:%M:%S'))"
    NOTIFY_MSG="Alle vorgesehenen Update-Schritte wurden ohne Fehler ausgeführt."
else
    warning "Update mit Teilfehlern abgeschlossen (${UPDATE_WARNINGS[*]}). Bitte Terminalausgabe prüfen. ($(date '+%H:%M:%S'))"
    NOTIFY_MSG="Update abgeschlossen, aber mit Warnungen bei: ${UPDATE_WARNINGS[*]}. Bitte Terminal prüfen."
    EXIT_CODE=1
fi

printf '%b%s %s%b\n' "$REBOOT_COLOR" "$REBOOT_ICON" "$REBOOT_MSG" "$RESET"

if [[ "$DNF_UPGRADE_SKIPPED" == "true" ]]; then
    warning "Das DNF-Update wurde wegen kritischer Befunde der Vorabprüfung nicht ausgeführt. Details stehen oben."
fi

if [[ ${#DNF_SKIPPED[@]} -gt 0 ]]; then
    warning "DNF hat Updates wegen Abhängigkeitskonflikten übersprungen: $(join_list "${DNF_SKIPPED[@]}")."
    if [[ ${#DNF_BLOCKERS[@]} -gt 0 ]]; then
        printf '%b  Ursache: Diese installierten Pakete setzen noch die alten Versionen voraus: %s. Abhilfe: auf ein passendes Update dieser Pakete warten oder sie entfernen. Details stehen oben in der DNF-Ausgabe.%b\n' \
            "$YELLOW" "$(join_list "${DNF_BLOCKERS[@]}")" "$RESET"
    else
        printf '%b  Details stehen oben in der DNF-Ausgabe.%b\n' "$YELLOW" "$RESET"
    fi
fi

if [[ ${#FLATPAK_EOL_RUNTIMES[@]} -gt 0 ]]; then
    eol_apps="unbekannt"
    if [[ ${#FLATPAK_EOL_APPS[@]} -gt 0 ]]; then
        eol_apps=$(IFS=,; printf '%s' "${FLATPAK_EOL_APPS[*]}")
        eol_apps=${eol_apps//,/, }
    fi
    printf '%bℹ Hinweis: Veraltete Flatpak-Laufzeitumgebungen (end-of-life) werden noch genutzt und bleiben daher installiert. Betroffene Apps: %s. Abhilfe schafft nur ein Update der App durch ihre Entwickler.%b\n' \
        "$BLUE" "$eol_apps" "$RESET"
fi

# Desktop-Benachrichtigung senden (nicht im Dry-Run und nur mit aktiver Desktop-Session, z.B. nicht über SSH)
if [[ "$DRY_RUN" != "true" ]] && command -v notify-send &>/dev/null && [[ -n "${DBUS_SESSION_BUS_ADDRESS:-}" ]]; then
    notify-send "System-Update abgeschlossen" "$(printf "%s\n%s" "$NOTIFY_MSG" "$REBOOT_MSG")" -i system-software-update || true
fi

exit "$EXIT_CODE"
