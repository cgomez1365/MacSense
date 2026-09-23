import tkinter as tk
from tkinter import messagebox
from tkinter import ttk
import subprocess
import threading
import re

def get_cpu_usage():
    try:
        output = subprocess.check_output("top -l 1 -n 0 | grep 'CPU usage'", shell=True).decode()
        parts = output.split(',')
        idle = float(parts[2].split('%')[0].strip())
        return 100.0 - idle
    except:
        return 0.0

def get_ram_usage():
    try:
        page_size = int(subprocess.check_output("pagesize", shell=True).decode().strip())
        vm_stat = subprocess.check_output("vm_stat", shell=True).decode()
        lines = vm_stat.split('\n')
        
        stats = {}
        for line in lines:
            if ':' in line:
                key, val = line.split(':')
                stats[key.strip()] = int(val.strip().strip('.')) * page_size
                
        total_ram = int(subprocess.check_output("sysctl -n hw.memsize", shell=True).decode().strip())
        free_ram = stats.get('Pages free', 0) + stats.get('Pages speculative', 0)
        used_ram = total_ram - free_ram
        return (used_ram / total_ram) * 100, used_ram, total_ram
    except:
        return 0.0, 0, 0

def get_disk_usage():
    try:
        output = subprocess.check_output("df -h /", shell=True).decode().split('\n')[1]
        parts = output.split()
        total = parts[1]
        used = parts[2]
        percent = parts[4]
        return percent, used, total
    except:
        return "0%", "0", "0"

def get_gpu_stats():
    try:
        output = subprocess.check_output("ioreg -l | grep 'PerformanceStatistics'", shell=True).decode()
        activity = re.search(r'"GPU Activity\(%\)"=(\d+)', output)
        temp = re.search(r'"Temperature\(C\)"=(\d+)', output)
        fan = re.search(r'"Fan Speed\(RPM\)"=(\d+)', output)
        
        gpu_act = activity.group(1) if activity else "N/A"
        gpu_temp = temp.group(1) if temp else "N/A"
        gpu_fan = fan.group(1) if fan else "N/A"
        
        return gpu_act, gpu_temp, gpu_fan
    except:
        return "N/A", "N/A", "N/A"

class MacSenseApp:
    def __init__(self, root):
        self.root = root
        self.root.title("MacSense - Nitro Dashboard")
        self.root.geometry("600x500")
        self.root.configure(bg="#0f0f0f") # Deep dark for gamer feel
        self.root.attributes("-topmost", True)
        
        # Style
        style = ttk.Style()
        style.theme_use('clam')
        style.configure("TProgressbar", thickness=15, background="#ff003c", troughcolor="#333333")
        
        title = tk.Label(root, text="M A C   S E N S E", fg="#ff003c", bg="#0f0f0f", font=("Helvetica", 24, "bold", "italic"))
        title.pack(pady=15)
        
        # Dashboard Frame
        dash_frame = tk.Frame(root, bg="#1a1a1a", bd=2, relief=tk.FLAT)
        dash_frame.pack(fill=tk.BOTH, expand=True, padx=20, pady=10)
        
        # CPU
        self.cpu_label = tk.Label(dash_frame, text="CPU Usage: --%", fg="#00ffcc", bg="#1a1a1a", font=("Helvetica", 12, "bold"))
        self.cpu_label.grid(row=0, column=0, sticky="w", padx=20, pady=10)
        self.cpu_bar = ttk.Progressbar(dash_frame, orient="horizontal", length=200, mode="determinate", style="TProgressbar")
        self.cpu_bar.grid(row=0, column=1, padx=20)

        # GPU
        self.gpu_label = tk.Label(dash_frame, text="GPU Activity: --%", fg="#00ffcc", bg="#1a1a1a", font=("Helvetica", 12, "bold"))
        self.gpu_label.grid(row=1, column=0, sticky="w", padx=20, pady=10)
        self.gpu_bar = ttk.Progressbar(dash_frame, orient="horizontal", length=200, mode="determinate", style="TProgressbar")
        self.gpu_bar.grid(row=1, column=1, padx=20)
        
        # Temps & Fan
        self.temp_label = tk.Label(dash_frame, text="GPU Temp: -- °C   |   Fan: -- RPM", fg="#ffcc00", bg="#1a1a1a", font=("Helvetica", 12, "bold"))
        self.temp_label.grid(row=2, column=0, columnspan=2, pady=15)
        
        # RAM
        self.ram_label = tk.Label(dash_frame, text="RAM Usage: --%", fg="#00ffcc", bg="#1a1a1a", font=("Helvetica", 12, "bold"))
        self.ram_label.grid(row=3, column=0, sticky="w", padx=20, pady=10)
        self.ram_bar = ttk.Progressbar(dash_frame, orient="horizontal", length=200, mode="determinate", style="TProgressbar")
        self.ram_bar.grid(row=3, column=1, padx=20)
        
        # Disk
        self.disk_label = tk.Label(dash_frame, text="Disk Usage: --%", fg="#00ffcc", bg="#1a1a1a", font=("Helvetica", 12, "bold"))
        self.disk_label.grid(row=4, column=0, sticky="w", padx=20, pady=10)
        self.disk_bar = ttk.Progressbar(dash_frame, orient="horizontal", length=200, mode="determinate", style="TProgressbar")
        self.disk_bar.grid(row=4, column=1, padx=20)
        
        # Buttons
        btn_frame = tk.Frame(root, bg="#0f0f0f")
        btn_frame.pack(pady=20)
        
        btn_clean_disk = tk.Button(btn_frame, text="ONE-CLICK DISK CLEAN", command=self.clean_disk, bg="#ff003c", fg="white", font=("Helvetica", 10, "bold"), highlightbackground="#0f0f0f")
        btn_clean_disk.grid(row=0, column=0, padx=10)
        
        btn_free_ram = tk.Button(btn_frame, text="ONE-CLICK RAM FREE", command=self.free_ram, bg="#ff003c", fg="white", font=("Helvetica", 10, "bold"), highlightbackground="#0f0f0f")
        btn_free_ram.grid(row=0, column=1, padx=10)
        
        self.update_stats()
        
    def update_stats(self):
        def fetch():
            cpu = get_cpu_usage()
            ram_pct, ram_used, ram_total = get_ram_usage()
            disk_pct, disk_used, disk_total = get_disk_usage()
            gpu_act, gpu_temp, gpu_fan = get_gpu_stats()
            self.root.after(0, self.refresh_ui, cpu, ram_pct, ram_used, ram_total, disk_pct, disk_used, disk_total, gpu_act, gpu_temp, gpu_fan)
            
        threading.Thread(target=fetch, daemon=True).start()
        self.root.after(2000, self.update_stats)

    def refresh_ui(self, cpu, ram_pct, ram_used, ram_total, disk_pct, disk_used, disk_total, gpu_act, gpu_temp, gpu_fan):
        # CPU
        self.cpu_label.config(text=f"CPU Usage: {cpu:.1f}%")
        self.cpu_bar['value'] = cpu
        
        # GPU
        if gpu_act != "N/A":
            self.gpu_label.config(text=f"GPU Activity: {gpu_act}%")
            self.gpu_bar['value'] = float(gpu_act)
        
        # Temps
        self.temp_label.config(text=f"GPU Temp: {gpu_temp} °C   |   Fan: {gpu_fan} RPM")
        
        # RAM
        ram_gb = ram_used / (1024**3)
        total_gb = ram_total / (1024**3)
        self.ram_label.config(text=f"RAM Usage: {ram_gb:.1f} / {total_gb:.1f} GB")
        self.ram_bar['value'] = ram_pct
        
        # Disk
        self.disk_label.config(text=f"Disk Usage: {disk_used} / {disk_total}")
        disk_val = float(disk_pct.strip('%')) if '%' in disk_pct else 0
        self.disk_bar['value'] = disk_val

    def clean_disk(self):
        result = messagebox.askyesno("Clean Caches", "Execute one-click disk cleanup? (Removes temporary caches)")
        if result:
            try:
                subprocess.run("rm -rf ~/Library/Caches/*", shell=True)
                messagebox.showinfo("Success", "Disk caches cleared successfully!")
            except Exception as e:
                messagebox.showerror("Error", f"Failed to clear caches: {e}")

    def free_ram(self):
        result = messagebox.askyesno("Free RAM", "Execute one-click RAM cleanup? (Safely closes heavy background apps like Chrome/Claude)")
        if result:
            try:
                subprocess.run("osascript -e 'quit app \"Google Chrome\"'", shell=True)
                subprocess.run("osascript -e 'quit app \"Claude\"'", shell=True)
                subprocess.run("osascript -e 'quit app \"Slack\"'", shell=True)
                messagebox.showinfo("Success", "Heavy apps have been closed. RAM cleared!")
            except Exception as e:
                messagebox.showerror("Error", f"Failed to free RAM: {e}")

if __name__ == "__main__":
    root = tk.Tk()
    app = MacSenseApp(root)
    root.mainloop()
