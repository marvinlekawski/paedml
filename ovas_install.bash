#!/bin/bash
## Version 0.3.0
##



##########################################################################################
##  Skript prüft vorher, ob die VMs bereits existieren, bevor es Boot-Reihenfolge setzt#
##  Erkennung von Netzwerkschnittstellen verbessert									 
##  LVM-Erstellung bleibt erhalten, falls nötig
##  Boot-Reihenfolge wird exakt nach Vorgabe gesetzt (Firewall zuerst, Nextcloud zuletzt)
##  VLANs sauberer konfiguriert
##  Fehlerbehandlung robuster (set -euo pipefail)
## Änderungen:
##  Verbesserte Fehlerbehandlung (set -e, || exit 1) && Abbrechungen variable gesetzt.
##  Sicheres Passwort-Handling // Passwort nicht mehr sichtbar, in der Vorherigen Version wars sichtbar.
##  Erkennung von Enterprise vs. Community Repos automatisch, nicht mehr mit JA/NEIN.
##  Robustere Paketinstallation // Zeigt sofortige fehler an.
##  Verbesserte LVM-Erstellung
##  Benutzerentscheidung für Neustart
## Automatische Erkennung der Netzwerkschnittstellen
## VLAN-Konfiguration basierend auf erkannter Netzwerkkarte
## Hinzugefügt: SCSI-Controller auf VirtIO SCSI umstellen bei allen OVA-Dateien
## Zusätzliche Tools für OVA-Bearbeitung
set -euo pipefail ## Verbesserung zur abbrechung.

# Prüfen, ob Root-Rechte vorhanden sind
if [[ $EUID -ne 0 ]]; then
   echo "Dieses Skript muss als Root ausgeführt werden!" >&2
   exit 1
fi

# Prüfen, ob Internetverbindung vorhanden ist
if ! ping -c 1 8.8.8.8 &>/dev/null; then
    echo "Keine Internetverbindung! Bitte prüfen." >&2
    exit 1
fi

# Pakete installieren
NEEDED_PKGS=("wget" "sudo" "qemu-guest-agent" "lshw" "qemu-utils")
for pkg in "${NEEDED_PKGS[@]}"; do
    if ! dpkg -s "$pkg" &>/dev/null; then
        echo "Installiere $pkg..."
        apt update && apt install -y "$pkg"
    fi
done

# Benutzerabfrage
read -p "Bitte gib deine MLI-Nummer ein: " MLI_NUMMER
read -s -p "Bitte gib dein Passwort ein: " PASSWORT
echo ""

read -p "Soll das Skript automatisch ausgeführt werden? (1 = Ja, 0 = Nein): " entscheidung
if [[ "$entscheidung" -ne 1 ]]; then
    echo "Manuelle Ausführung gewählt. Beende Skript."
    exit 0
fi

# Proxmox Repository setzen
if grep -q "proxmox.com" /etc/apt/sources.list.d/pve-enterprise.list; then
    echo "Enterprise Repository erkannt."
    PVE_REPO="pve-enterprise"
else
    echo "Community Repository erkannt."
    PVE_REPO="pve-no-subscription"
    echo "deb http://download.proxmox.com/debian/pve bookworm $PVE_REPO" > /etc/apt/sources.list.d/pve-community.list
fi

# Proxmox Installation
apt update && apt full-upgrade -y
apt install -y proxmox-ve postfix open-iscsi

# LVM erkennen und erstellen
DISK=$(lsblk -dpno NAME,TYPE | awk '$2=="disk"{print $1}' | head -n1)
if [[ -n "$DISK" && ! -d "/dev/pve" ]]; then
    echo "Erstelle LVM auf $DISK..."
    pvcreate "$DISK" && vgcreate pve "$DISK"
fi

# Netzwerkkarte erkennen
NIC=$(ip -o link show | awk -F': ' '{print $2}' | grep -E 'eth|ens' | head -n 1)
if [[ -z "$NIC" ]]; then
    echo "Keine Netzwerkkarte gefunden!" >&2
    exit 1
fi
echo "Netzwerkkarte erkannt: $NIC"

# VLANs konfigurieren
cat <<EOF >> /etc/network/interfaces

auto vmbr1
iface vmbr1 inet manual
    bridge-ports none
    bridge-stp off
    bridge-fd 0
    vlan-aware yes

auto vmbr10
iface vmbr10 inet manual
    bridge-ports $NIC
    bridge-stp off
    bridge-fd 0
    vlan-aware yes
    description "GAESTE"

auto vmbr20
iface vmbr20 inet manual
    bridge-ports $NIC
    bridge-stp off
    bridge-fd 0
    vlan-aware yes
    description "INTERNET"

auto vmbr30
iface vmbr30 inet manual
    bridge-ports $NIC
    bridge-stp off
    bridge-fd 0
    vlan-aware yes
    description "MDM"

auto vmbr40
iface vmbr40 inet manual
    bridge-ports $NIC
    bridge-stp off
    bridge-fd 0
    vlan-aware yes
    description "PAEDAGOGIK"
EOF

systemctl restart networking
echo "VLANs eingerichtet."

# OVA-Handling
OVA_URL="https://$MLI_NUMMER:$PASSWORT@paedml-linux.support-netz.de/paedml/linux/version_80"
OVA_FILES=("80_Firewall.ova" "80_Server.ova" "80_opsi-Server.ova" "80_AdminVM.ova" "Nextcloud_V4.ova")

declare -A VM_NAMES=(
    ["80_Firewall.ova"]="Firewall"
    ["80_Server.ova"]="Server"
    ["80_opsi-Server.ova"]="Opsi-Server"
    ["80_AdminVM.ova"]="AdminVM"
    ["Nextcloud_V4.ova"]="Nextcloud"
)

for ova in "${OVA_FILES[@]}"; do
    if [[ ! -f "$ova" ]]; then
        echo "Lade $ova herunter..."
        wget --tries=5 --timeout=40 --user="$MLI_NUMMER" --password="$PASSWORT" "$OVA_URL/$ova" -O "$ova"
		## Versuche liegen bei 5x
		## Timeout liegt bei 40s, danach wird der Vorgang abgebrochen.
    fi

    echo "Entpacke $ova..."
    mkdir -p "$ova-extracted"
    tar -xf "$ova" -C "$ova-extracted"

    VMX_FILE=$(find "$ova-extracted" -type f -name "*.vmx" | head -n 1)
    if [[ -f "$VMX_FILE" ]]; then
        sed -i '/scsi0.virtualDev/d' "$VMX_FILE"
        echo 'scsi0.virtualDev = "virtio-scsi"' >> "$VMX_FILE"
    fi

    echo "Erstelle OVA neu..."
    tar -cf "$ova" -C "$ova-extracted" .
    rm -rf "$ova-extracted"
done

# Startreihenfolge setzen
echo "Setze Startreihenfolge der VMs..."
declare -A BOOT_ORDER=(
    ["Firewall"]=10
    ["Server"]=20
    ["Opsi-Server"]=30
    ["AdminVM"]=40
    ["Nextcloud"]=50
)

for VM_NAME in "${!BOOT_ORDER[@]}"; do
    VMID=$(qm list | grep "$VM_NAME" | awk '{print $1}')
    if [[ -n "$VMID" ]]; then
        qm set "$VMID" --bootorder "${BOOT_ORDER[$VM_NAME]}"
        echo "Startreihenfolge für $VM_NAME gesetzt auf ${BOOT_ORDER[$VM_NAME]}"
        echo "Starte VM: $VM_NAME (ID: $VMID)..."
        qm start "$VMID"
        echo "Warte 120 Sekunden, bevor die nächste VM gestartet wird..."
        sleep 120 ## Sleep 120 Sekunden
    else
		## VM wurde nicht gefunden, er überspringt genau diese VM.
        echo "VM $VM_NAME nicht gefunden, überspringe."
		##
    fi
done

## Reboot - mal testen obs nötig ist.
read -p "Soll das System jetzt neu gestartet werden? (y/N) " REBOOT
if [[ "$REBOOT" =~ ^[Yy]$ ]]; then
    reboot
fi

echo "Installation abgeschlossen."
