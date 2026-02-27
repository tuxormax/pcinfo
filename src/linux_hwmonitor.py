#!/usr/bin/env python3
"""
LinuxHWMonitor - Hardware Monitor for Linux
Inspired by CrystalDiskInfo + HWiNFO64
Requires: pip install PyQt5 psutil
Optional: sudo apt install smartmontools lm-sensors
"""

import sys
import os
import subprocess
import re
import json
import glob
import psutil
from pathlib import Path
from datetime import datetime

from PyQt5.QtWidgets import (
    QApplication, QMainWindow, QWidget, QVBoxLayout, QHBoxLayout,
    QTabWidget, QLabel, QPushButton, QTableWidget, QTableWidgetItem,
    QHeaderView, QFrame, QScrollArea, QGridLayout, QSizePolicy,
    QGroupBox, QStatusBar, QToolBar, QAction, QSplitter, QComboBox,
    QProgressBar
)
from PyQt5.QtCore import Qt, QTimer, QThread, pyqtSignal, QSize
from PyQt5.QtGui import (
    QFont, QColor, QPalette, QIcon, QPixmap, QPainter, QBrush,
    QPen, QLinearGradient, QFontDatabase
)

# ─────────────────────────────────────────────
#  STYLESHEET
# ─────────────────────────────────────────────
STYLE = """
QMainWindow, QDialog {
    background-color: #0d1117;
}
QWidget {
    background-color: #0d1117;
    color: #e6edf3;
    font-family: 'Consolas', 'Liberation Mono', monospace;
    font-size: 15px;
}
QTabWidget::pane {
    border: 1px solid #30363d;
    background-color: #161b22;
}
QTabBar::tab {
    background-color: #21262d;
    color: #8b949e;
    padding: 8px 20px;
    border: 1px solid #30363d;
    border-bottom: none;
    font-size: 15px;
    font-weight: bold;
}
QTabBar::tab:selected {
    background-color: #161b22;
    color: #58a6ff;
    border-bottom: 2px solid #58a6ff;
}
QTabBar::tab:hover:!selected {
    background-color: #30363d;
    color: #e6edf3;
}
QTableWidget {
    background-color: #0d1117;
    alternate-background-color: #161b22;
    gridline-color: #21262d;
    border: 1px solid #30363d;
    color: #e6edf3;
    selection-background-color: #1f3a5f;
    selection-color: #58a6ff;
}
QTableWidget::item {
    padding: 4px 8px;
    border-bottom: 1px solid #21262d;
}
QHeaderView::section {
    background-color: #21262d;
    color: #8b949e;
    padding: 6px 8px;
    border: none;
    border-bottom: 2px solid #30363d;
    font-weight: bold;
    font-size: 14px;
    text-transform: uppercase;
    letter-spacing: 1px;
}
QScrollBar:vertical {
    background-color: #0d1117;
    width: 12px;
    border: none;
}
QScrollBar::handle:vertical {
    background-color: #30363d;
    border-radius: 6px;
    min-height: 20px;
}
QScrollBar::handle:vertical:hover {
    background-color: #58a6ff;
}
QScrollBar::add-line:vertical, QScrollBar::sub-line:vertical { height: 0; }
QScrollBar:horizontal {
    background-color: #0d1117;
    height: 12px;
    border: none;
}
QScrollBar::handle:horizontal {
    background-color: #30363d;
    border-radius: 6px;
}
QScrollBar::handle:horizontal:hover { background-color: #58a6ff; }
QScrollBar::add-line:horizontal, QScrollBar::sub-line:horizontal { width: 0; }
QPushButton {
    background-color: #21262d;
    color: #e6edf3;
    border: 1px solid #30363d;
    border-radius: 4px;
    padding: 6px 14px;
    font-size: 15px;
}
QPushButton:hover {
    background-color: #30363d;
    border-color: #58a6ff;
    color: #58a6ff;
}
QPushButton:pressed { background-color: #1f3a5f; }
QGroupBox {
    border: 1px solid #30363d;
    border-radius: 6px;
    margin-top: 14px;
    padding-top: 8px;
    color: #58a6ff;
    font-weight: bold;
    font-size: 15px;
}
QGroupBox::title {
    subcontrol-origin: margin;
    subcontrol-position: top left;
    left: 10px;
    padding: 0 6px;
    color: #58a6ff;
}
QProgressBar {
    border: 1px solid #30363d;
    border-radius: 4px;
    background-color: #0d1117;
    text-align: center;
    color: #e6edf3;
    height: 16px;
    font-size: 14px;
}
QProgressBar::chunk {
    border-radius: 3px;
    background: qlineargradient(x1:0, y1:0, x2:1, y2:0,
        stop:0 #1f6feb, stop:1 #58a6ff);
}
QLabel { background-color: transparent; }
QComboBox {
    background-color: #21262d;
    border: 1px solid #30363d;
    border-radius: 4px;
    padding: 4px 10px;
    color: #e6edf3;
    min-width: 180px;
}
QComboBox:hover { border-color: #58a6ff; }
QComboBox QAbstractItemView {
    background-color: #21262d;
    border: 1px solid #30363d;
    selection-background-color: #1f3a5f;
}
QStatusBar {
    background-color: #161b22;
    color: #8b949e;
    border-top: 1px solid #30363d;
    font-size: 14px;
}
QSplitter::handle {
    background-color: #30363d;
    width: 2px;
}
QToolBar {
    background-color: #161b22;
    border-bottom: 1px solid #30363d;
    spacing: 4px;
    padding: 4px;
}
"""

# ─────────────────────────────────────────────
#  COLOR HELPERS
# ─────────────────────────────────────────────
def health_color(status):
    colors = {
        "Good":    "#3fb950",
        "Caution": "#d29922",
        "Bad":     "#f85149",
        "Unknown": "#8b949e",
    }
    return colors.get(status, "#8b949e")

def usage_color(pct):
    if pct < 60:  return "#3fb950"
    if pct < 80:  return "#d29922"
    return "#f85149"

def temp_color(temp):
    if temp is None: return "#8b949e"
    if temp < 40:   return "#3fb950"
    if temp < 55:   return "#d29922"
    return "#f85149"


# ─────────────────────────────────────────────
#  PARTITION BAR WIDGET  (estilo macOS)
# ─────────────────────────────────────────────
# Paleta de colores para particiones
_PART_COLORS = [
    "#58a6ff",  # azul
    "#3fb950",  # verde
    "#d29922",  # amarillo
    "#f78166",  # naranja
    "#bc8cff",  # violeta
    "#39d353",  # verde claro
    "#ff7b72",  # rojo suave
    "#79c0ff",  # azul claro
]

class PartitionBarWidget(QWidget):
    """Visual disk partition bar, estilo macOS Disk Utility"""

    def __init__(self, partitions=None, parent=None):
        super().__init__(parent)
        self.partitions = partitions or []
        self.setMinimumHeight(20)
        self.setMaximumHeight(24)

    def set_partitions(self, partitions):
        self.partitions = partitions
        self.update()

    def paintEvent(self, event):
        p = QPainter(self)
        p.setRenderHint(QPainter.Antialiasing)
        W = self.width()
        H = self.height()
        r = 5  # border radius

        # Background
        p.setBrush(QBrush(QColor("#21262d")))
        p.setPen(Qt.NoPen)
        p.drawRoundedRect(0, 0, W, H, r, r)

        if not self.partitions:
            p.end()
            return

        # Calculate total size
        total = sum(pt.get("total_gb") or 0 for pt in self.partitions)
        if total <= 0:
            # Fallback: equal width
            total = len(self.partitions)
            for pt in self.partitions:
                if not pt.get("total_gb"):
                    pt["total_gb"] = 1.0

        x = 0
        for i, pt in enumerate(self.partitions):
            gb = pt.get("total_gb") or 0
            frac = gb / total if total else 0
            seg_w = int(frac * W)
            if i == len(self.partitions) - 1:
                seg_w = W - x  # fill remainder

            color = QColor(_PART_COLORS[i % len(_PART_COLORS)])
            used_pct = pt.get("percent")
            if used_pct is not None:
                if used_pct > 90:
                    color = QColor("#f85149")
                elif used_pct > 75:
                    color = QColor("#d29922")

            # Draw segment
            if x == 0 and seg_w >= W - 2:
                # Full bar
                p.setBrush(QBrush(color))
                p.drawRoundedRect(x, 0, seg_w, H, r, r)
            elif x == 0:
                # Left end rounded
                p.setBrush(QBrush(color))
                p.drawRoundedRect(x, 0, seg_w + r, H, r, r)
                p.drawRect(x + seg_w - r, 0, r, H)
            elif x + seg_w >= W:
                # Right end rounded
                p.setBrush(QBrush(color))
                p.drawRoundedRect(x - r, 0, seg_w + r, H, r, r)
                p.drawRect(x - r, 0, r, H)
            else:
                # Middle: plain rect
                p.setBrush(QBrush(color))
                p.drawRect(x, 0, seg_w, H)

            # Divider
            if i < len(self.partitions) - 1:
                p.setPen(QPen(QColor("#0d1117"), 1))
                p.drawLine(x + seg_w, 0, x + seg_w, H)
                p.setPen(Qt.NoPen)

            x += seg_w

        p.end()


# ─────────────────────────────────────────────
#  DATA COLLECTION FUNCTIONS
# ─────────────────────────────────────────────

def run_cmd(cmd, timeout=8):
    try:
        r = subprocess.run(cmd, capture_output=True, text=True,
                           timeout=timeout, shell=isinstance(cmd, str))
        return r.stdout.strip()
    except Exception:
        return ""

def get_disks():
    """Returns list of dicts: {name, model, size, type}"""
    disks = []
    try:
        out = run_cmd(["lsblk", "-J", "-o", "NAME,MODEL,SIZE,ROTA,TYPE,MOUNTPOINTS"])
        data = json.loads(out)
        for dev in data.get("blockdevices", []):
            if dev.get("type") == "disk":
                disks.append({
                    "name":  dev.get("name", ""),
                    "model": (dev.get("model") or "Unknown").strip(),
                    "size":  dev.get("size", "?"),
                    "rotational": dev.get("rota", "1") == "1",
                    "path":  f"/dev/{dev.get('name','')}",
                })
    except Exception:
        # fallback
        for p in sorted(glob.glob("/dev/sd?") + glob.glob("/dev/nvme?n?")):
            name = os.path.basename(p)
            disks.append({"name": name, "model": name, "size": "?",
                          "rotational": True, "path": p})
    return disks

def get_smart_data(dev_path):
    """Run smartctl -a -j and parse output"""
    out = run_cmd(["sudo", "smartctl", "-a", "-j", dev_path])
    if not out:
        out = run_cmd(["smartctl", "-a", "-j", dev_path])
    result = {
        "health": "Unknown",
        "temp": None,
        "model": "",
        "firmware": "",
        "serial": "**************",
        "interface": "",
        "capacity": "",
        "power_on_hours": None,
        "power_on_count": None,
        "total_writes": None,
        "rotation_rate": None,
        "life_percent": None,
        "attributes": [],
        "nvme_log": {},
        "raw_output": "",
    }
    if not out:
        result["raw_output"] = "No se pudo obtener datos SMART.\nIntenta ejecutar con sudo."
        return result

    try:
        data = json.loads(out)
    except Exception:
        result["raw_output"] = out
        return result

    # Health
    smart_status = data.get("smart_status", {})
    if smart_status.get("passed") is True:
        result["health"] = "Good"
    elif smart_status.get("passed") is False:
        result["health"] = "Bad"

    # Model
    result["model"]    = data.get("model_name", "")
    result["firmware"] = data.get("firmware_version", "")
    result["serial"]   = "**************"  # masked
    result["interface"]= data.get("device", {}).get("protocol", "")
    cap = data.get("user_capacity", {})
    if cap:
        gb = cap.get("bytes", 0) / 1e9
        result["capacity"] = f"{gb:.1f} GB"

    # Temperature
    temp_data = data.get("temperature", {})
    if temp_data:
        result["temp"] = temp_data.get("current")

    # Power stats
    result["power_on_hours"] = data.get("power_on_time", {}).get("hours")
    result["power_on_count"] = data.get("power_cycle_count")

    # SATA attributes
    attrs = data.get("ata_smart_attributes", {}).get("table", [])
    for a in attrs:
        # Caution threshold check
        val  = a.get("value", 0)
        worst= a.get("worst", 0)
        thresh=a.get("thresh", 0)
        raw  = a.get("raw", {}).get("value", 0)
        flag = "Good"
        if worst <= thresh and thresh > 0:
            flag = "Caution" if val > thresh else "Bad"
        result["attributes"].append({
            "id":    f"{a.get('id', 0):03d}",
            "name":  a.get("name", ""),
            "flag":  flag,
            "value": val,
            "worst": worst,
            "thresh":thresh,
            "raw":   raw,
        })

    # SATA: vida útil — igual que CrystalDiskInfo
    # Prioridad: attr 231 (SSD Life Left) > 177 (Wear Leveling Count) > 202
    if attrs:
        life_ids = {231: True, 202: True, 177: True}
        for a in result["attributes"]:
            try:
                aid = int(a["id"])
            except (ValueError, TypeError):
                continue
            if aid in life_ids:
                v = a["value"]
                if isinstance(v, int) and 0 <= v <= 100:
                    result["life_percent"] = v
                    break
        # Si no encontró atributo específico, HDD = 100%
        if result["life_percent"] is None and result["health"] != "Unknown":
            result["life_percent"] = 100

    # NVMe log
    nvme = data.get("nvme_smart_health_information_log", {})
    if nvme:
        result["nvme_log"] = nvme
        # NVMe written
        written = nvme.get("data_units_written", 0)
        result["total_writes"] = written * 512 * 1000 / 1e9  # GB approx

        # Temperature from NVMe
        if result["temp"] is None:
            result["temp"] = nvme.get("temperature", None)

        # Power
        if result["power_on_hours"] is None:
            result["power_on_hours"] = nvme.get("power_on_hours")
        if result["power_on_count"] is None:
            result["power_on_count"] = nvme.get("power_cycles")

        # NVMe health
        pct_used = nvme.get("percentage_used", 0)
        if pct_used > 90:
            result["health"] = "Bad"
        elif pct_used > 50:
            result["health"] = "Caution"
        elif result["health"] == "Unknown":
            result["health"] = "Good"
        # Vida útil NVMe = 100 - porcentaje usado
        result["life_percent"] = max(0, 100 - pct_used)

        # Add NVMe as pseudo-attributes
        nvme_attrs = [
            ("Critical Warning",       nvme.get("critical_warning", 0)),
            ("Temperature",            f"{nvme.get('temperature','-')} °C"),
            ("Available Spare",        f"{nvme.get('available_spare','-')} %"),
            ("Available Spare Thresh", f"{nvme.get('available_spare_threshold','-')} %"),
            ("Percentage Used",        f"{nvme.get('percentage_used','-')} %"),
            ("Data Units Read",        nvme.get("data_units_read", 0)),
            ("Data Units Written",     nvme.get("data_units_written", 0)),
            ("Host Read Commands",     nvme.get("host_reads", 0)),
            ("Host Write Commands",    nvme.get("host_writes", 0)),
            ("Controller Busy Time",   nvme.get("controller_busy_time", 0)),
            ("Power Cycles",           nvme.get("power_cycles", 0)),
            ("Power On Hours",         nvme.get("power_on_hours", 0)),
            ("Unsafe Shutdowns",       nvme.get("unsafe_shutdowns", 0)),
            ("Media Errors",           nvme.get("media_errors", 0)),
            ("Num Error Log Entries",  nvme.get("num_err_log_entries", 0)),
        ]
        for name, raw in nvme_attrs:
            result["attributes"].append({
                "id": "---", "name": name, "flag": "Good",
                "value": "-", "worst": "-", "thresh": "-", "raw": raw
            })

    return result

def get_disk_usage(dev_path):
    """Returns dict with partition info for the given disk using lsblk + psutil"""
    disk_name = os.path.basename(dev_path)   # e.g. "sda", "nvme0n1"
    partitions_info = []

    try:
        # Get full partition tree via lsblk
        out = run_cmd(["lsblk", "-J", "-o", "NAME,SIZE,FSTYPE,MOUNTPOINTS,LABEL,TYPE,PARTLABEL", dev_path])
        data = json.loads(out)
        devices = data.get("blockdevices", [])
        if not devices:
            return None

        def collect_children(node):
            results = []
            for child in node.get("children", []):
                ntype = child.get("type", "")
                if ntype in ("part", "lvm", "crypt", "dm"):
                    mounts = child.get("mountpoints", []) or []
                    mounts = [m for m in mounts if m]
                    fstype = child.get("fstype") or ""
                    label  = child.get("label") or child.get("partlabel") or child.get("name","")
                    size   = child.get("size","?")
                    part   = {
                        "name":    child.get("name",""),
                        "size":    size,
                        "fstype":  fstype,
                        "label":   label,
                        "mounts":  mounts,
                        "used_gb": None,
                        "free_gb": None,
                        "total_gb": None,
                        "percent": None,
                    }
                    # Try to get usage from mount point
                    for mp in mounts:
                        try:
                            u = psutil.disk_usage(mp)
                            part["used_gb"]  = u.used  / 1e9
                            part["free_gb"]  = u.free  / 1e9
                            part["total_gb"] = u.total / 1e9
                            part["percent"]  = u.percent
                            break
                        except Exception:
                            pass
                    results.append(part)
                # Recurse into LVM/LUKS children
                results.extend(collect_children(child))
            return results

        disk_node = devices[0]
        partitions_info = collect_children(disk_node)

        # Also try raw disk usage if no partitions found
        if not partitions_info:
            for mp in ["/", "/boot", "/home"]:
                try:
                    u = psutil.disk_usage(mp)
                    partitions_info.append({
                        "name": disk_name,
                        "size": f"{u.total/1e9:.1f}G",
                        "fstype": "",
                        "label": "/",
                        "mounts": [mp],
                        "used_gb": u.used/1e9,
                        "free_gb": u.free/1e9,
                        "total_gb": u.total/1e9,
                        "percent": u.percent,
                    })
                    break
                except Exception:
                    pass

    except Exception:
        # Pure psutil fallback
        try:
            parts = psutil.disk_partitions(all=False)
            for p in parts:
                pdev = os.path.basename(p.device)
                if pdev.startswith(disk_name) and len(pdev) > len(disk_name):
                    try:
                        u = psutil.disk_usage(p.mountpoint)
                        partitions_info.append({
                            "name": pdev,
                            "size": f"{u.total/1e9:.1f}G",
                            "fstype": p.fstype,
                            "label": p.mountpoint,
                            "mounts": [p.mountpoint],
                            "used_gb": u.used/1e9,
                            "free_gb": u.free/1e9,
                            "total_gb": u.total/1e9,
                            "percent": u.percent,
                        })
                    except Exception:
                        pass
        except Exception:
            pass

    return partitions_info if partitions_info else None



    try:
        return Path(path).read_text().strip()
    except Exception:
        return default

def get_cpu_info():
    """Detección completa de CPU desde /proc/cpuinfo y dmidecode"""
    info = {
        "model": "Unknown", "vendor": "", "family": "", "stepping": "",
        "cores": 0, "threads": 0, "sockets": 0,
        "freq_base": 0, "freq_max": 0, "freq_min": 0,
        "cache_l1d": "", "cache_l1i": "", "cache_l2": "", "cache_l3": "",
        "flags": [], "microcode": "", "architecture": "",
        "tdp": "", "codename": "", "process_node": "",
        "virtualization": "",
    }

    try:
        cpuinfo = Path("/proc/cpuinfo").read_text()
        blocks = [b for b in cpuinfo.split("\n\n") if b.strip()]
        sockets = set()
        for blk in blocks:
            d = {}
            for line in blk.split("\n"):
                if ":" in line:
                    k, _, v = line.partition(":")
                    d[k.strip()] = v.strip()
            sockets.add(d.get("physical id", "0"))

        # First CPU block
        d = {}
        for line in blocks[0].split("\n"):
            if ":" in line:
                k, _, v = line.partition(":")
                d[k.strip()] = v.strip()

        info["model"]       = d.get("model name", "Unknown")
        info["vendor"]      = d.get("vendor_id", "")
        info["family"]      = d.get("cpu family", "")
        info["stepping"]    = d.get("stepping", "")
        info["microcode"]   = d.get("microcode", "")
        info["flags"]       = d.get("flags", "").split()[:20]  # primeras 20
        info["cores"]       = psutil.cpu_count(logical=False) or 1
        info["threads"]     = psutil.cpu_count(logical=True) or 1
        info["sockets"]     = len(sockets) or 1

        freq = psutil.cpu_freq()
        if freq:
            info["freq_base"] = round(freq.current)
            info["freq_max"]  = round(freq.max)
            info["freq_min"]  = round(freq.min)

        # Cache sizes
        for blk in blocks:
            for line in blk.split("\n"):
                if "cache size" in line.lower():
                    info["cache_l3"] = line.split(":")[1].strip()
                    break
    except Exception:
        pass

    # Cache via /sys
    base = "/sys/devices/system/cpu/cpu0/cache"
    if os.path.isdir(base):
        for idx_dir in sorted(glob.glob(f"{base}/index*")):
            try:
                level = _read_file(f"{idx_dir}/level")
                ctype = _read_file(f"{idx_dir}/type")
                size  = _read_file(f"{idx_dir}/size")
                if level == "1" and ctype == "Data":        info["cache_l1d"] = size
                elif level == "1" and ctype == "Instruction": info["cache_l1i"] = size
                elif level == "2":                           info["cache_l2"]  = size
                elif level == "3":                           info["cache_l3"]  = size
            except Exception:
                pass

    # Architecture
    info["architecture"] = run_cmd(["uname", "-m"]) or "x86_64"

    # Virtualization support
    if "vmx" in info["flags"]:   info["virtualization"] = "VT-x (Intel)"
    elif "svm" in info["flags"]: info["virtualization"] = "AMD-V"

    # dmidecode para TDP / codename (requiere sudo)
    dmi = run_cmd(["sudo", "dmidecode", "-t", "processor"])
    if dmi:
        for line in dmi.split("\n"):
            l = line.strip()
            if l.startswith("External Clock:"):
                pass  # bus speed
            if l.startswith("Max Speed:"):
                info["freq_max"] = info["freq_max"] or int(re.sub(r"[^\d]","",l) or 0)
            if l.startswith("Core Count:"):
                info["cores"] = info["cores"] or int(re.sub(r"[^\d]","",l) or 0)
            if l.startswith("Thread Count:"):
                info["threads"] = info["threads"] or int(re.sub(r"[^\d]","",l) or 0)

    return info


def get_gpu_info():
    """Detectar GPU(s) mediante lspci, /sys DRM y glxinfo/nvidia-smi"""
    gpus = []

    # lspci base
    lspci = run_cmd(["lspci", "-mmv"])
    current = {}
    for line in lspci.split("\n"):
        line = line.strip()
        if not line:
            if current.get("Class","").lower() in ("vga compatible controller",
               "display controller", "3d controller", "processing accelerators"):
                gpus.append(dict(current))
            current = {}
            continue
        if ":" in line:
            k, _, v = line.partition(":")
            current[k.strip()] = v.strip()

    # Enriquecer con info adicional
    result = []
    for g in gpus:
        name    = g.get("Device", g.get("SVendor","Unknown GPU"))
        vendor  = g.get("Vendor", "")
        slot    = g.get("Slot",   "")
        gpu = {
            "name":    name,
            "vendor":  vendor,
            "slot":    slot,
            "driver":  "",
            "vram_mb": 0,
            "vram_str": "",
            "resolution": "",
            "api_gl":   "",
            "api_vk":   "",
            "compute":  "",
            "temp":     None,
            "extra":    {},
        }
        result.append(gpu)

    # /sys DRM para VRAM
    for drm in sorted(glob.glob("/sys/class/drm/card*/device")):
        vram_f = f"{drm}/mem_info_vram_total"
        driver_f= f"{drm}/driver"
        if os.path.exists(vram_f):
            try:
                vram = int(_read_file(vram_f)) // (1024*1024)
                driver = os.path.basename(os.readlink(driver_f)) if os.path.islink(driver_f) else ""
                # Find matching GPU
                if result:
                    result[0]["vram_mb"]  = vram
                    result[0]["vram_str"] = f"{vram} MB" if vram < 1024 else f"{vram//1024} GB"
                    result[0]["driver"]   = driver
            except Exception:
                pass

    # nvidia-smi
    nsmi = run_cmd(["nvidia-smi",
        "--query-gpu=name,driver_version,memory.total,temperature.gpu,pcie.link.gen.current",
        "--format=csv,noheader,nounits"])
    if nsmi:
        for i, line in enumerate(nsmi.strip().split("\n")):
            parts = [x.strip() for x in line.split(",")]
            if len(parts) >= 4:
                entry = {
                    "name":    parts[0],
                    "vendor":  "NVIDIA",
                    "driver":  f"nvidia {parts[1]}",
                    "vram_mb": int(parts[2]) if parts[2].isdigit() else 0,
                    "vram_str":f"{int(parts[2])//1024} GB" if parts[2].isdigit() else parts[2]+" MB",
                    "temp":    int(parts[3]) if parts[3].isdigit() else None,
                    "slot":    "", "resolution": "", "api_gl": "", "api_vk": "",
                    "compute": parts[4] if len(parts)>4 else "",
                    "extra":   {},
                }
                if i < len(result):
                    result[i].update(entry)
                else:
                    result.append(entry)

    # glxinfo para OpenGL version
    glx = run_cmd(["glxinfo", "-B"])
    if glx:
        for line in glx.split("\n"):
            if "OpenGL version" in line and result:
                result[0]["api_gl"] = line.split(":")[-1].strip()
            if "OpenGL renderer" in line and result and not result[0]["name"]:
                result[0]["name"] = line.split(":")[-1].strip()

    # vulkaninfo
    vk = run_cmd(["vulkaninfo", "--summary"])
    if vk:
        for line in vk.split("\n"):
            if "apiVersion" in line and result:
                result[0]["api_vk"] = line.split("=")[-1].strip()
                break

    if not result:
        result.append({
            "name": "No se detectó GPU (instala lspci)",
            "vendor": "", "driver": "", "vram_mb": 0, "vram_str": "",
            "temp": None, "slot": "", "resolution": "",
            "api_gl": "", "api_vk": "", "compute": "", "extra": {}
        })
    return result


def get_motherboard_info():
    """Detectar motherboard via dmidecode y /sys"""
    info = {
        "manufacturer": "", "model": "", "version": "",
        "serial": "**************",
        "bios_vendor": "", "bios_version": "", "bios_date": "",
        "bios_type": "",
        "chipset": "",
        "slots_pcie": [], "slots_used": 0,
        "sata_ports": 0,
    }

    # /sys fallback (no necesita sudo)
    info["manufacturer"] = _read_file("/sys/class/dmi/id/board_vendor")
    info["model"]        = _read_file("/sys/class/dmi/id/board_name")
    info["version"]      = _read_file("/sys/class/dmi/id/board_version")
    info["bios_vendor"]  = _read_file("/sys/class/dmi/id/bios_vendor")
    info["bios_version"] = _read_file("/sys/class/dmi/id/bios_version")
    info["bios_date"]    = _read_file("/sys/class/dmi/id/bios_date")

    # BIOS type (UEFI or Legacy)
    uefi_check = run_cmd(["ls", "/sys/firmware/efi"])
    info["bios_type"] = "UEFI" if uefi_check else "Legacy BIOS"

    # dmidecode para más detalles (con sudo)
    dmi_board = run_cmd(["sudo", "dmidecode", "-t", "2"])
    if dmi_board:
        for line in dmi_board.split("\n"):
            l = line.strip()
            if l.startswith("Manufacturer:") and not info["manufacturer"]:
                info["manufacturer"] = l.split(":",1)[1].strip()
            if l.startswith("Product Name:") and not info["model"]:
                info["model"] = l.split(":",1)[1].strip()
            if l.startswith("Version:") and not info["version"]:
                info["version"] = l.split(":",1)[1].strip()

    # Chipset via lspci
    lspci_all = run_cmd(["lspci"])
    chipsets = []
    for line in lspci_all.split("\n"):
        if "ISA bridge" in line or "Host bridge" in line:
            parts = line.split(" ", 1)
            if len(parts) > 1:
                chipsets.append(parts[1].strip())
    info["chipset"] = chipsets[0] if chipsets else ""

    # PCIe slots
    dmi_slots = run_cmd(["sudo", "dmidecode", "-t", "9"])
    current_slot = {}
    for line in (dmi_slots or "").split("\n"):
        l = line.strip()
        if l.startswith("System Slot Information"):
            if current_slot: info["slots_pcie"].append(current_slot)
            current_slot = {}
        elif ":" in l:
            k, _, v = l.partition(":")
            current_slot[k.strip()] = v.strip()
    if current_slot: info["slots_pcie"].append(current_slot)
    info["slots_used"] = sum(1 for s in info["slots_pcie"]
                             if s.get("Current Usage","").lower() == "in use")

    # SATA ports
    info["sata_ports"] = len(glob.glob("/sys/class/ata_port/ata*"))

    return info


def get_ram_info():
    """Detectar módulos de RAM via dmidecode"""
    modules = []
    total_bytes = psutil.virtual_memory().total

    dmi = run_cmd(["sudo", "dmidecode", "-t", "17"])
    if dmi:
        current = {}
        for line in dmi.split("\n"):
            l = line.strip()
            if l.startswith("Memory Device"):
                if current: modules.append(current)
                current = {}
            elif ":" in l:
                k, _, v = l.partition(":")
                current[k.strip()] = v.strip()
        if current: modules.append(current)

    # Filter only populated slots
    populated = [m for m in modules if m.get("Size","") not in ("No Module Installed","","Unknown")]

    if not populated:
        # fallback from /proc/meminfo
        vm = psutil.virtual_memory()
        populated = [{
            "Size": f"{vm.total // (1024**3)} GB",
            "Type": "DDR",
            "Speed": "Unknown",
            "Manufacturer": "Unknown",
            "Part Number": "Unknown",
            "Locator": "DIMM 0",
            "Bank Locator": "",
            "Form Factor": "",
            "Data Width": "",
        }]

    # Also get total slots count
    total_slots = len(modules)

    return {
        "modules": populated,
        "total_slots": total_slots,
        "populated_slots": len(populated),
        "total_gb": total_bytes / 1e9,
        "type": populated[0].get("Type","") if populated else "",
        "speed_mhz": populated[0].get("Speed","") if populated else "",
        "channel": _detect_ram_channel(populated),
    }

def _detect_ram_channel(modules):
    if len(modules) >= 4: return "Quad-Channel"
    if len(modules) == 2:
        # Check if they're in different banks
        banks = set(m.get("Bank Locator","") for m in modules)
        return "Dual-Channel" if len(banks) >= 2 else "Dual-Channel (probable)"
    if len(modules) == 1: return "Single-Channel"
    return "Unknown"


# ─────────────────────────────────────────────
#  CUSTOM WIDGETS
# ─────────────────────────────────────────────
class HealthBadge(QWidget):
    """Big colored health status badge — shows status + vida útil %"""
    def __init__(self, status="Unknown", percent=None, parent=None):
        super().__init__(parent)
        self.status  = status
        self.percent = percent
        self.setMinimumSize(120, 80)
        self.setMaximumSize(140, 92)

    def set_status(self, status, percent=None):
        self.status  = status
        self.percent = percent
        self.update()

    def paintEvent(self, event):
        p = QPainter(self)
        p.setRenderHint(QPainter.Antialiasing)
        color = QColor(health_color(self.status))

        # Background fill
        p.setBrush(QBrush(color))
        p.setPen(QPen(color.darker(120), 2))
        p.drawRoundedRect(2, 2, self.width()-4, self.height()-4, 8, 8)

        # Status text
        p.setPen(QColor("#ffffff"))
        font = QFont("Consolas", 16, QFont.Bold)
        p.setFont(font)
        rect = self.rect()
        if self.percent is not None:
            # Status on upper half
            upper = rect.adjusted(0, 4, 0, -rect.height()//2)
            p.drawText(upper, Qt.AlignCenter, self.status)
            # Percent on lower half
            font2 = QFont("Consolas", 13, QFont.Bold)
            p.setFont(font2)
            lower = rect.adjusted(0, rect.height()//2 - 4, 0, -4)
            p.drawText(lower, Qt.AlignCenter, f"{self.percent}%")
        else:
            p.drawText(rect, Qt.AlignCenter, self.status)
        p.end()


class TempWidget(QWidget):
    """Temperature display widget"""
    def __init__(self, temp=None, parent=None):
        super().__init__(parent)
        self.temp = temp
        self.setMinimumSize(96, 68)
        self.setMaximumSize(116, 78)

    def set_temp(self, temp):
        self.temp = temp
        self.update()

    def paintEvent(self, event):
        p = QPainter(self)
        p.setRenderHint(QPainter.Antialiasing)
        color = QColor(temp_color(self.temp))

        p.setBrush(QBrush(QColor("#161b22")))
        p.setPen(QPen(color, 2))
        p.drawRoundedRect(2, 2, self.width()-4, self.height()-4, 8, 8)

        p.setPen(color)
        font = QFont("Consolas", 17, QFont.Bold)
        p.setFont(font)
        text = f"{self.temp}°C" if self.temp is not None else "--°C"
        p.drawText(self.rect(), Qt.AlignCenter, text)
        p.end()


class DiskButton(QPushButton):
    """Disk selector button — lives inside the S.M.A.R.T. panel"""
    def __init__(self, disk, health="Unknown", temp=None, parent=None):
        super().__init__(parent)
        self.disk   = disk
        self.health = health
        self.temp   = temp
        self.setCheckable(True)
        self._build()

    def _build(self):
        color    = health_color(self.health)
        temp_str = f"{self.temp}°C" if self.temp else "--°C"
        icon     = "💾" if self.disk.get("rotational") else "⚡"
        self.setText(f"{icon}  {self.disk['name']}\n{self.health}   {temp_str}")
        self.setStyleSheet(f"""
            QPushButton {{
                background-color: #0d1117;
                color: {color};
                border: 2px solid {color}55;
                border-radius: 8px;
                padding: 10px 18px;
                font-size: 14px;
                font-weight: bold;
                min-width: 120px;
                text-align: center;
                line-height: 1.6;
            }}
            QPushButton:hover {{
                background-color: #161b22;
                border-color: {color};
            }}
            QPushButton:checked {{
                background-color: #132030;
                border: 2px solid #58a6ff;
                color: #58a6ff;
            }}
        """)


# ─────────────────────────────────────────────
#  DISK INFO PANEL
# ─────────────────────────────────────────────
class DiskInfoPanel(QWidget):
    def __init__(self, parent=None):
        super().__init__(parent)
        self._disk_buttons = []
        self._current_disk = None
        self._build_ui()

    def _build_ui(self):
        layout = QVBoxLayout(self)
        layout.setSpacing(0)
        layout.setContentsMargins(0, 0, 0, 0)

        # ── Row 1: disk selector buttons ──────────────
        selector_frame = QFrame()
        selector_frame.setStyleSheet(
            "background-color: #161b22; border-bottom: 2px solid #30363d;"
        )
        selector_frame.setFixedHeight(80)
        sel_layout = QHBoxLayout(selector_frame)
        sel_layout.setContentsMargins(12, 8, 12, 8)
        sel_layout.setSpacing(8)

        self._no_disk_lbl = QLabel("  Buscando discos...")
        self._no_disk_lbl.setStyleSheet("color: #8b949e; font-size: 15px;")
        sel_layout.addWidget(self._no_disk_lbl)
        sel_layout.addStretch()

        self._scan_btn = QPushButton("⟳  Escanear discos")
        self._scan_btn.setFixedHeight(56)
        self._scan_btn.setFixedWidth(180)
        sel_layout.addWidget(self._scan_btn)

        self._sel_layout = sel_layout
        self._sel_frame  = selector_frame
        layout.addWidget(selector_frame)

        # ── Row 2: modelo / nombre del disco ──────────
        self.model_label = QLabel("Selecciona un disco")
        self.model_label.setStyleSheet(
            "background-color: #161b22; color: #58a6ff; font-size: 18px;"
            "font-weight: bold; padding: 9px 16px; border-bottom: 1px solid #30363d;"
        )
        layout.addWidget(self.model_label)

        # ── Row 3: info strip (health + campos + temp) ─
        info_strip = QFrame()
        info_strip.setStyleSheet(
            "background-color: #161b22; border-bottom: 1px solid #30363d;"
        )
        info_strip.setFixedHeight(128)
        strip_l = QHBoxLayout(info_strip)
        strip_l.setContentsMargins(14, 10, 14, 10)
        strip_l.setSpacing(14)

        # Health badge
        self.health_badge = HealthBadge("Unknown")
        strip_l.addWidget(self.health_badge)

        def vsep():
            s = QFrame(); s.setFrameShape(QFrame.VLine)
            s.setStyleSheet("color: #30363d;"); return s

        strip_l.addWidget(vsep())

        # Left info grid
        left_grid = QGridLayout()
        left_grid.setSpacing(3)
        left_grid.setHorizontalSpacing(10)
        self.lbl = {}
        left_fields = [
            ("Firmware",      "firmware"),
            ("Interface",     "interface"),
            ("Transfer Mode", "transfer_mode"),
            ("Standard",      "standard"),
            ("Drive",         "mountpoint"),
            ("Capacidad",     "capacity"),
            ("Features",      "features"),
            ("Espacio Usado", "space_used"),
            ("Espacio Libre", "space_free"),
        ]
        for i, (label, key) in enumerate(left_fields):
            row, col = divmod(i, 3)
            lname = QLabel(label)
            lname.setStyleSheet("color: #8b949e; font-size: 13px;")
            lval  = QLabel("--")
            lval.setStyleSheet("color: #e6edf3; font-size: 14px;")
            lval.setWordWrap(True)
            left_grid.addWidget(lname, row, col * 2)
            left_grid.addWidget(lval,  row, col * 2 + 1)
            self.lbl[key] = lval
        strip_l.addLayout(left_grid)

        strip_l.addStretch()
        strip_l.addWidget(vsep())

        # Right stats
        right_grid = QGridLayout()
        right_grid.setSpacing(4)
        right_grid.setHorizontalSpacing(16)
        right_fields = [
            ("Total Host Writes", "total_writes"),
            ("Rotation Rate",     "rotation_rate"),
            ("Power On Count",    "power_on_count"),
            ("Power On Hours",    "power_on_hours"),
        ]
        for row, (label, key) in enumerate(right_fields):
            ln = QLabel(label)
            ln.setStyleSheet("color: #8b949e; font-size: 13px;")
            lv = QLabel("--")
            lv.setStyleSheet("color: #e6edf3; font-size: 14px; font-weight: bold;")
            lv.setAlignment(Qt.AlignRight | Qt.AlignVCenter)
            right_grid.addWidget(ln, row, 0)
            right_grid.addWidget(lv, row, 1)
            self.lbl[key] = lv
        strip_l.addLayout(right_grid)

        strip_l.addWidget(vsep())

        # Temperature box
        temp_col = QVBoxLayout()
        temp_col.setAlignment(Qt.AlignCenter)
        temp_lbl = QLabel("Temperatura")
        temp_lbl.setStyleSheet("color: #8b949e; font-size: 13px;")
        temp_lbl.setAlignment(Qt.AlignCenter)
        self.temp_widget = TempWidget()
        temp_col.addWidget(temp_lbl)
        temp_col.addWidget(self.temp_widget)
        strip_l.addLayout(temp_col)

        layout.addWidget(info_strip)

        # ── Row 4: S.M.A.R.T. attribute table ─────────
        self.table = QTableWidget()
        self.table.setColumnCount(7)
        self.table.setHorizontalHeaderLabels([
            "ID", "Attribute Name", "Status", "Value", "Worst", "Threshold", "Raw Value"
        ])
        self.table.horizontalHeader().setSectionResizeMode(1, QHeaderView.Stretch)
        self.table.horizontalHeader().setSectionResizeMode(0, QHeaderView.ResizeToContents)
        for col in (2, 3, 4, 5, 6):
            self.table.horizontalHeader().setSectionResizeMode(col, QHeaderView.ResizeToContents)
        self.table.setAlternatingRowColors(True)
        self.table.setSelectionBehavior(QTableWidget.SelectRows)
        self.table.verticalHeader().setVisible(False)
        self.table.setEditTriggers(QTableWidget.NoEditTriggers)
        self.table.setShowGrid(False)
        layout.addWidget(self.table)

        # ── Row 5: Partition view (macOS style) ───────
        part_frame = QFrame()
        part_frame.setStyleSheet(
            "background-color: #161b22; border-top: 1px solid #30363d;"
        )
        part_outer = QVBoxLayout(part_frame)
        part_outer.setContentsMargins(14, 10, 14, 12)
        part_outer.setSpacing(6)

        part_title = QLabel("Particiones del disco")
        part_title.setStyleSheet(
            "color: #58a6ff; font-size: 14px; font-weight: bold; background: transparent;"
        )
        part_outer.addWidget(part_title)

        self.part_bar = PartitionBarWidget()
        part_outer.addWidget(self.part_bar)

        # Legend area (labels below bar)
        self._part_legend = QWidget()
        self._part_legend.setStyleSheet("background: transparent;")
        self._part_legend_layout = QHBoxLayout(self._part_legend)
        self._part_legend_layout.setContentsMargins(0, 4, 0, 0)
        self._part_legend_layout.setSpacing(16)
        part_outer.addWidget(self._part_legend)

        layout.addWidget(part_frame)

    # ── Public API ─────────────────────────────────────
    def populate_disks(self, disks, on_select_cb):
        """Called from MainWindow after disk scan. Adds a button per disk."""
        # Clear old buttons
        for btn in self._disk_buttons:
            self._sel_layout.removeWidget(btn)
            btn.deleteLater()
        self._disk_buttons = []

        self._no_disk_lbl.setVisible(not disks)

        for disk in disks:
            btn = DiskButton(disk)
            btn.clicked.connect(lambda checked, d=disk, b=btn: self._btn_clicked(d, b, on_select_cb))
            # Insert before the stretch + scan button (last 2 items)
            pos = self._sel_layout.count() - 2   # before stretch
            self._sel_layout.insertWidget(pos, btn)
            self._disk_buttons.append(btn)

        # Select first automatically
        if self._disk_buttons:
            self._disk_buttons[0].setChecked(True)
            self._btn_clicked(disks[0], self._disk_buttons[0], on_select_cb)

    def _btn_clicked(self, disk, active_btn, callback):
        for btn in self._disk_buttons:
            btn.setChecked(btn is active_btn)
        callback(disk, active_btn)

    def refresh_button(self, btn, health, temp):
        btn.health = health
        btn.temp   = temp
        btn._build()
        btn.setChecked(True)

    def load_disk(self, disk):
        self.model_label.setText(f"⏳  Leyendo S.M.A.R.T. de {disk['path']}...")
        QApplication.processEvents()

        data = get_smart_data(disk["path"])
        partitions = get_disk_usage(disk["path"])   # list of partition dicts or None

        icon = "💾" if disk.get("rotational") else "⚡"
        self.model_label.setText(
            f"{icon}  {data['model'] or disk['model']}  —  {data['capacity'] or disk['size']}"
        )

        self.health_badge.set_status(data["health"], data.get("life_percent"))
        self.temp_widget.set_temp(data["temp"])

        self.lbl["firmware"].setText(data.get("firmware") or "--")
        self.lbl["interface"].setText(data.get("interface") or "--")
        self.lbl["transfer_mode"].setText(
            "SATA/600 | SATA/600" if "SATA" in (data.get("interface") or "") else "--"
        )
        self.lbl["standard"].setText("ACS-4 | ACS-4 Revision 5")
        self.lbl["capacity"].setText(data.get("capacity") or "--")
        self.lbl["features"].setText("S.M.A.R.T., NCQ, TRIM, DevSleep")
        self.lbl["mountpoint"].setText(disk["path"])

        # Espacio libre / usado — sumar todas las particiones con datos
        if partitions:
            total_used = sum(p["used_gb"]  for p in partitions if p.get("used_gb") is not None)
            total_free = sum(p["free_gb"]  for p in partitions if p.get("free_gb") is not None)
            total_gb   = sum(p["total_gb"] for p in partitions if p.get("total_gb") is not None)
            if total_gb > 0:
                pct = (total_used / total_gb) * 100
                self.lbl["space_used"].setText(f"{total_used:.1f} GB  ({pct:.0f}%)")
                self.lbl["space_used"].setStyleSheet(
                    f"color: {'#f85149' if pct>90 else '#d29922' if pct>75 else '#e6edf3'};"
                    "font-size: 14px;"
                )
                self.lbl["space_free"].setText(f"{total_free:.1f} GB  ({100-pct:.0f}%)")
            else:
                self.lbl["space_used"].setText("Particiones sin montar")
                self.lbl["space_free"].setText("--")
        else:
            self.lbl["space_used"].setText("--")
            self.lbl["space_free"].setText("--")

        poh = data.get("power_on_hours")
        poc = data.get("power_on_count")
        tw  = data.get("total_writes")
        self.lbl["power_on_hours"].setText(f"{poh:,} h" if poh else "--")
        self.lbl["power_on_count"].setText(f"{poc:,}" if poc else "--")
        self.lbl["total_writes"].setText(f"{tw:,.0f} GB" if tw else "--")
        self.lbl["rotation_rate"].setText(
            "---- (SSD)" if not disk.get("rotational") else "7200 RPM"
        )

        # Table
        attrs = data["attributes"]
        self.table.setRowCount(len(attrs))
        for row, a in enumerate(attrs):
            items = [
                (a["id"],          "#8b949e"),
                (str(a["name"]),   "#e6edf3"),
                (a["flag"],        health_color(a["flag"])),
                (str(a["value"]),  "#e6edf3"),
                (str(a["worst"]),  "#8b949e"),
                (str(a["thresh"]), "#8b949e"),
                (str(a["raw"]),    "#3fb950"),
            ]
            for col, (text, color) in enumerate(items):
                item = QTableWidgetItem(text)
                item.setForeground(QColor(color))
                if col == 2:
                    item.setFont(QFont("Consolas", 14, QFont.Bold))
                self.table.setItem(row, col, item)
            self.table.setRowHeight(row, 26)

        if not attrs:
            self.table.setRowCount(1)
            item = QTableWidgetItem(
                data.get("raw_output") or
                "No se encontraron atributos SMART.\n"
                "Intenta ejecutar con sudo para acceso completo."
            )
            item.setForeground(QColor("#8b949e"))
            self.table.setItem(0, 0, item)
            self.table.setSpan(0, 0, 1, 7)

        # Partition bar + legend
        self._update_partition_view(partitions or [])

        return data["health"], data["temp"]

    def _update_partition_view(self, partitions):
        """Refresh the macOS-style partition bar and legend labels"""
        self.part_bar.set_partitions(partitions)

        # Clear old legend
        while self._part_legend_layout.count():
            item = self._part_legend_layout.takeAt(0)
            if item.widget():
                item.widget().deleteLater()

        if not partitions:
            no_lbl = QLabel("No se detectaron particiones montadas")
            no_lbl.setStyleSheet("color: #8b949e; font-size: 13px;")
            self._part_legend_layout.addWidget(no_lbl)
            self._part_legend_layout.addStretch()
            return

        for i, pt in enumerate(partitions):
            color = _PART_COLORS[i % len(_PART_COLORS)]
            used_pct = pt.get("percent")
            if used_pct and used_pct > 90:   color = "#f85149"
            elif used_pct and used_pct > 75: color = "#d29922"

            # Colored dot
            dot = QLabel("●")
            dot.setStyleSheet(f"color: {color}; font-size: 16px; background: transparent;")

            # Text: label / mount · size · used%
            name   = pt.get("label") or pt.get("name","")
            mounts = pt.get("mounts", [])
            mp_str = mounts[0] if mounts else "sin montar"
            gb_str = f"{pt['total_gb']:.1f} GB" if pt.get("total_gb") else pt.get("size","?")
            pct_str = f"  {used_pct:.0f}% usado" if used_pct is not None else ""
            fstype = f"  [{pt['fstype']}]" if pt.get("fstype") else ""

            info_lbl = QLabel(f"{name}  ·  {mp_str}  ·  {gb_str}{pct_str}{fstype}")
            info_lbl.setStyleSheet("color: #e6edf3; font-size: 13px; background: transparent;")

            box = QWidget()
            box.setStyleSheet("background: transparent;")
            bx = QHBoxLayout(box)
            bx.setContentsMargins(0, 0, 0, 0)
            bx.setSpacing(4)
            bx.addWidget(dot)
            bx.addWidget(info_lbl)

            self._part_legend_layout.addWidget(box)

        self._part_legend_layout.addStretch()


# ─────────────────────────────────────────────
#  SYSTEM INFO PANEL
# ─────────────────────────────────────────────

def _info_row(label, value, label_w=200, val_color="#e6edf3"):
    """Helper: returns a QWidget with label + value in a row"""
    w = QWidget()
    w.setStyleSheet("background: transparent;")
    l = QHBoxLayout(w)
    l.setContentsMargins(0, 1, 0, 1)
    l.setSpacing(0)
    lbl = QLabel(label)
    lbl.setFixedWidth(label_w)
    lbl.setStyleSheet("color: #8b949e; font-size: 14px; padding-left: 4px;")
    val = QLabel(str(value) if value else "—")
    val.setStyleSheet(f"color: {val_color}; font-size: 14px; font-weight: bold;")
    val.setWordWrap(True)
    l.addWidget(lbl)
    l.addWidget(val, 1)
    return w


def _section_header(title):
    lbl = QLabel(title)
    lbl.setStyleSheet(
        "color: #58a6ff; font-size: 13px; font-weight: bold;"
        "padding: 8px 4px 4px 4px; background: transparent;"
        "border-bottom: 1px solid #30363d;"
    )
    return lbl


class InfoBox(QGroupBox):
    """GroupBox que renderiza filas campo-valor"""
    def __init__(self, title, rows, parent=None):
        super().__init__(title, parent)
        vl = QVBoxLayout(self)
        vl.setSpacing(0)
        vl.setContentsMargins(8, 14, 8, 8)
        for label, value, *rest in rows:
            color = rest[0] if rest else "#e6edf3"
            vl.addWidget(_info_row(label, value, val_color=color))


class SystemInfoPanel(QWidget):
    def __init__(self, parent=None):
        super().__init__(parent)
        layout = QVBoxLayout(self)
        layout.setContentsMargins(0, 0, 0, 0)
        layout.setSpacing(0)

        # Header bar
        hdr = QFrame()
        hdr.setStyleSheet("background-color: #161b22; border-bottom: 1px solid #30363d;")
        hdr.setFixedHeight(44)
        hdr_l = QHBoxLayout(hdr)
        hdr_l.setContentsMargins(14, 0, 14, 0)
        title = QLabel("System Summary")
        title.setStyleSheet("color: #58a6ff; font-size: 15px; font-weight: bold;")
        hdr_l.addWidget(title)
        hdr_l.addStretch()
        self._scan_btn = QPushButton("  🔍  Escanear hardware  ")
        self._scan_btn.clicked.connect(self.refresh)
        hdr_l.addWidget(self._scan_btn)
        layout.addWidget(hdr)

        # Scroll area
        scroll = QScrollArea()
        scroll.setWidgetResizable(True)
        scroll.setFrameShape(QFrame.NoFrame)
        self._container = QWidget()
        self._cl = QVBoxLayout(self._container)
        self._cl.setSpacing(10)
        self._cl.setContentsMargins(12, 12, 12, 12)
        scroll.setWidget(self._container)
        layout.addWidget(scroll)

        # Loading label
        self._loading = QLabel("  ⏳  Detectando hardware...")
        self._loading.setStyleSheet("color: #8b949e; font-size: 13px; padding: 20px;")
        self._cl.addWidget(self._loading)

        # Don't auto-scan on startup - user clicks button
        # But do a lightweight scan
        QTimer.singleShot(200, self.refresh)

    def _clear(self):
        for i in reversed(range(self._cl.count())):
            item = self._cl.itemAt(i)
            if item and item.widget():
                item.widget().deleteLater()

    def refresh(self):
        self._scan_btn.setEnabled(False)
        self._scan_btn.setText("  ⏳  Escaneando...  ")
        QApplication.processEvents()
        self._clear()

        # ─── CPU ───────────────────────────────────
        cpu = get_cpu_info()
        cpu_rows = [
            ("Modelo",          cpu["model"],         "#e6edf3"),
            ("Vendor",          cpu["vendor"],         "#8b949e"),
            ("Familia / Stepping", f"{cpu['family']} / {cpu['stepping']}", "#8b949e"),
            ("Núcleos físicos", str(cpu["cores"]),      "#3fb950"),
            ("Hilos (threads)", str(cpu["threads"]),    "#3fb950"),
            ("Sockets",         str(cpu["sockets"]),    "#8b949e"),
            ("Frecuencia base", f"{cpu['freq_base']} MHz" if cpu['freq_base'] else "—", "#58a6ff"),
            ("Frecuencia máx.", f"{cpu['freq_max']} MHz" if cpu['freq_max'] else "—",  "#58a6ff"),
            ("Frecuencia mín.", f"{cpu['freq_min']} MHz" if cpu['freq_min'] else "—",  "#8b949e"),
            ("Caché L1d / L1i", f"{cpu['cache_l1d']} / {cpu['cache_l1i']}" if cpu['cache_l1d'] else "—", "#8b949e"),
            ("Caché L2",        cpu["cache_l2"] or "—", "#8b949e"),
            ("Caché L3",        cpu["cache_l3"] or "—", "#8b949e"),
            ("Microcode",       cpu["microcode"] or "—","#8b949e"),
            ("Arquitectura",    cpu["architecture"],   "#8b949e"),
            ("Virtualización",  cpu["virtualization"] or "—", "#d29922"),
            ("Instrucciones",   " ".join(cpu["flags"][:12]) + ("…" if len(cpu["flags"])>12 else ""), "#8b949e"),
        ]
        cpu_box = InfoBox(f"🖥  CPU  —  {cpu['model']}", cpu_rows)
        self._cl.addWidget(cpu_box)

        # ─── GPU(s) ────────────────────────────────
        gpus = get_gpu_info()
        for gi, gpu in enumerate(gpus):
            vram = gpu.get("vram_str") or "—"
            api_gl = gpu.get("api_gl") or "—"
            api_vk = gpu.get("api_vk") or "—"
            temp_s = f"{gpu['temp']} °C" if gpu.get("temp") is not None else "—"
            gpu_rows = [
                ("Nombre",       gpu["name"],              "#e6edf3"),
                ("Vendor",       gpu["vendor"],             "#8b949e"),
                ("Slot PCI",     gpu["slot"],               "#8b949e"),
                ("Driver",       gpu["driver"] or "—",      "#58a6ff"),
                ("VRAM",         vram,                      "#3fb950"),
                ("Temperatura",  temp_s,                    temp_color(gpu.get("temp")) if gpu.get("temp") else "#8b949e"),
                ("OpenGL",       api_gl,                    "#8b949e"),
                ("Vulkan",       api_vk,                    "#8b949e"),
                ("Resolución",   gpu.get("resolution") or "—", "#8b949e"),
            ]
            label = f"GPU {gi}" if len(gpus) > 1 else "GPU"
            gpu_box = InfoBox(f"🎮  {label}  —  {gpu['name']}", gpu_rows)
            self._cl.addWidget(gpu_box)

        # ─── Tarjeta Madre ─────────────────────────
        mb = get_motherboard_info()
        slots_str = (f"{mb['slots_used']} / {len(mb['slots_pcie'])} en uso"
                     if mb["slots_pcie"] else "—")
        mb_rows = [
            ("Fabricante",       mb["manufacturer"],    "#e6edf3"),
            ("Modelo",           mb["model"],           "#e6edf3"),
            ("Versión",          mb["version"],         "#8b949e"),
            ("Chipset",          mb["chipset"] or "—",  "#58a6ff"),
            ("BIOS Vendor",      mb["bios_vendor"],     "#8b949e"),
            ("BIOS Versión",     mb["bios_version"],    "#58a6ff"),
            ("BIOS Fecha",       mb["bios_date"],       "#8b949e"),
            ("BIOS Tipo",        mb["bios_type"],       "#3fb950"),
            ("Puertos SATA",     str(mb["sata_ports"]) if mb["sata_ports"] else "—", "#8b949e"),
            ("Slots PCIe",       slots_str,             "#8b949e"),
        ]
        mb_box = InfoBox(
            f"🔧  Tarjeta Madre  —  {mb['manufacturer']} {mb['model']}",
            mb_rows
        )
        self._cl.addWidget(mb_box)

        # ─── RAM ───────────────────────────────────
        ram = get_ram_info()
        total_gb = ram["total_gb"]
        ram_header_rows = [
            ("Total instalada",   f"{total_gb:.1f} GB",            "#3fb950"),
            ("Slots usados",      f"{ram['populated_slots']} / {ram['total_slots']}", "#58a6ff"),
            ("Tipo",              ram["type"],                      "#58a6ff"),
            ("Velocidad",         ram["speed_mhz"],                 "#58a6ff"),
            ("Modo de canal",     ram["channel"],                   "#d29922"),
        ]
        ram_box = InfoBox(f"💾  Memoria RAM  —  {total_gb:.1f} GB  {ram['type']}", ram_header_rows)
        self._cl.addWidget(ram_box)

        # Individual RAM modules
        for i, mod in enumerate(ram["modules"]):
            slot_name = mod.get("Locator","") or mod.get("Bank Locator","") or f"DIMM {i}"
            bank = mod.get("Bank Locator","")
            size  = mod.get("Size","—")
            mtype = mod.get("Type","—")
            speed = mod.get("Speed","—")
            mfr   = mod.get("Manufacturer","—").strip()
            part  = mod.get("Part Number","—").strip()
            form  = mod.get("Form Factor","—")
            width = mod.get("Data Width","—")
            voltage = mod.get("Configured Voltage","—")
            mod_rows = [
                ("Tamaño",        size,        "#3fb950"),
                ("Tipo",          mtype,       "#58a6ff"),
                ("Velocidad",     speed,       "#58a6ff"),
                ("Fabricante",    mfr,         "#8b949e"),
                ("Part Number",   part,        "#8b949e"),
                ("Form Factor",   form,        "#8b949e"),
                ("Ancho de datos",width,       "#8b949e"),
                ("Voltaje",       voltage,     "#d29922"),
                ("Banco",         bank,        "#8b949e"),
            ]
            mod_box = InfoBox(
                f"  ┗  Slot: {slot_name}  ({size} {mtype} {speed})",
                mod_rows
            )
            mod_box.setStyleSheet("""
                QGroupBox {
                    border: 1px solid #21262d;
                    margin-top: 10px;
                    color: #8b949e;
                    font-size: 11px;
                }
                QGroupBox::title { color: #8b949e; }
            """)
            self._cl.addWidget(mod_box)

        # ─── Sistema Operativo ─────────────────────
        os_name     = _read_file("/etc/os-release").split("\n")
        os_pretty   = next((l.split("=")[1].strip('"') for l in os_name if l.startswith("PRETTY_NAME")), "Linux")
        kernel      = run_cmd(["uname", "-r"])
        hostname    = run_cmd(["hostname"])
        uptime_s    = int(_read_file("/proc/uptime").split()[0].split(".")[0]) if _read_file("/proc/uptime") else 0
        uptime_h    = f"{uptime_s//3600}h {(uptime_s%3600)//60}m"

        os_rows = [
            ("Sistema Operativo", os_pretty,              "#e6edf3"),
            ("Kernel",            kernel,                  "#58a6ff"),
            ("Hostname",          hostname,                "#8b949e"),
            ("Arquitectura",      run_cmd(["uname","-m"]),  "#8b949e"),
            ("Uptime",            uptime_h,                "#3fb950"),
        ]
        os_box = InfoBox("🐧  Sistema Operativo", os_rows)
        self._cl.addWidget(os_box)

        self._cl.addStretch()

        self._scan_btn.setEnabled(True)
        self._scan_btn.setText("  🔍  Escanear hardware  ")


# ─────────────────────────────────────────────
#  MAIN WINDOW
# ─────────────────────────────────────────────
class MainWindow(QMainWindow):
    def __init__(self):
        super().__init__()
        self.setWindowTitle("LinuxHWMonitor  v1.0")
        self.resize(1100, 780)
        self.setMinimumSize(860, 600)
        self._disks          = []
        self._current_disk   = None
        self._current_btn    = None

        self._build_ui()
        self._scan_disks()
        self._start_timer()

    def _build_ui(self):
        central = QWidget()
        self.setCentralWidget(central)
        main_l = QVBoxLayout(central)
        main_l.setSpacing(0)
        main_l.setContentsMargins(0, 0, 0, 0)

        # ── Tabs ──────────────────────────────────────
        # Order: 0 = Sistema & Hardware,  1 = Disco S.M.A.R.T.
        self.tabs = QTabWidget()
        self.tabs.setDocumentMode(True)

        self.system_panel = SystemInfoPanel()
        self.disk_panel   = DiskInfoPanel()

        # Connect the scan button inside DiskInfoPanel
        self.disk_panel._scan_btn.clicked.connect(self._scan_disks)

        self.tabs.addTab(self.system_panel, "  🖥  Sistema & Hardware  ")
        self.tabs.addTab(self.disk_panel,   "  💾  Disco (S.M.A.R.T.)  ")
        main_l.addWidget(self.tabs)

        # ── Status bar ────────────────────────────────
        self.status = QStatusBar()
        self.setStatusBar(self.status)
        self.status.setSizeGripEnabled(False)

        # Créditos — permanente a la izquierda
        author_lbl = QLabel(
            "  Creado por: tuxor  ·  tuxor.max@gmail.com  ·  v1.0  ·  2026"
        )
        author_lbl.setStyleSheet("color: #484f58; font-size: 13px; padding: 0 6px;")
        self.status.addWidget(author_lbl, 0)

        # Estado del escaneo — se actualiza pero no pisa créditos
        self.status_msg = QLabel("")
        self.status_msg.setStyleSheet("color: #6e7681; font-size: 13px; padding: 0 8px;")
        self.status.addWidget(self.status_msg, 1)

        # Reloj — permanente a la derecha
        self.status_time = QLabel("")
        self.status_time.setStyleSheet("color: #8b949e; padding: 0 8px; font-size: 13px;")
        self.status.addPermanentWidget(self.status_time)
        self._update_time()

    def _scan_disks(self):
        self.disk_panel._scan_btn.setEnabled(False)
        self.disk_panel._scan_btn.setText("⏳  Buscando...")
        QApplication.processEvents()

        self._disks = get_disks()
        self._current_disk = None
        self._current_btn  = None

        # Delegate button creation to the panel
        self.disk_panel.populate_disks(self._disks, self._on_disk_selected)

        n = len(self._disks)
        msg = f"✓  {n} disco(s) detectado(s)" if n else "⚠  No se encontraron discos"
        self.status_msg.setText(msg)
        self.disk_panel._scan_btn.setEnabled(True)
        self.disk_panel._scan_btn.setText("⟳  Escanear discos")

    def _on_disk_selected(self, disk, btn):
        """Called when user clicks a disk button inside DiskInfoPanel."""
        self._current_disk = disk
        self._current_btn  = btn
        # Switch to disk tab automatically
        self.tabs.setCurrentIndex(1)
        health, temp = self.disk_panel.load_disk(disk)
        self.disk_panel.refresh_button(btn, health, temp)

    def _start_timer(self):
        self._timer = QTimer(self)
        self._timer.timeout.connect(self._update_time)
        self._timer.start(1_000)   # update clock every second

    def _update_time(self):
        now = datetime.now().strftime("%Y-%m-%d  %H:%M:%S")
        self.status_time.setText(f"🕐  {now}")


# ─────────────────────────────────────────────
#  ENTRY POINT
# ─────────────────────────────────────────────
def main():
    app = QApplication(sys.argv)
    app.setApplicationName("LinuxHWMonitor")
    app.setStyle("Fusion")

    # Dark palette base
    palette = QPalette()
    palette.setColor(QPalette.Window,          QColor("#0d1117"))
    palette.setColor(QPalette.WindowText,      QColor("#e6edf3"))
    palette.setColor(QPalette.Base,            QColor("#161b22"))
    palette.setColor(QPalette.AlternateBase,   QColor("#0d1117"))
    palette.setColor(QPalette.Text,            QColor("#e6edf3"))
    palette.setColor(QPalette.Button,          QColor("#21262d"))
    palette.setColor(QPalette.ButtonText,      QColor("#e6edf3"))
    palette.setColor(QPalette.Highlight,       QColor("#1f6feb"))
    palette.setColor(QPalette.HighlightedText, QColor("#ffffff"))
    palette.setColor(QPalette.Link,            QColor("#58a6ff"))
    app.setPalette(palette)
    app.setStyleSheet(STYLE)

    win = MainWindow()
    win.show()
    sys.exit(app.exec_())


if __name__ == "__main__":
    main()
