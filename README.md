[![License](https://img.shields.io/badge/Open%20Source-MIT-brightgreen.svg)](https://opensource.org/licenses/MIT)

# cpuTopBars

A lightweight CPU monitoring tool designed specifically for the macOS menu bar. Keep a pulse on your system performance without cluttering your workspace.

* **hiding in the menu bar:**

![cpuTopBars Screenshot](Screenshot-menu.png)

* **showing settings, readings and processes:**

![cpuTopBars Screenshot](Screenshot-menu-preferences.png)

## 🚀 Features

`cpuTopBars` provides real-time insights into your system's CPU usage with a focus on aesthetics and customization.

* **Real-time Menu Bar Visualization:** View your CPU activity at a glance with a live-updating graph right in your macOS menu bar, beside small bars for disk, memory, overall CPU and GPU use, a bar that shows when the Neural Engine is powered on, and bars for the efficiency cores' and the performance cores' use, each of these two heading its own cores' bars when the graph shows each core and the Mac lists its efficiency cores first (switchable in Settings).
* **Top Process Tracking:** Quickly identify which of your processes are consuming the most CPU with a ranked list of "Your Top Processes by CPU", each with its CPU share and its memory (physical footprint, in GB); processes of other users, among them macOS's system daemons and WindowServer, are counted in one row below it.
* **System readings:** when the menu opens, a panel beside it shows uptime, then startup-volume, memory and overall CPU usage as percentages with their sizes, the disk and memory with their free and used space, memory with its swap in use and CPU with its efficiency and performance cores' use, GPU use and whether the Neural Engine is powered on, all read on the Mac; nothing is sent over the network.
* **Hover labels:** rest the pointer on a bar for a second to see its value below the menu bar; on the core bars it lists each core's load.
* **Process inspector:** click a process in the menu to open a window with its man page, where it has one, and its arguments and environment.
* **Freeze:** pause the process list to examine it while the CPU graph keeps running; while frozen, rest on a ↳ row to see what it is a helper of.
* **Launch at login:** turn it on in Settings to open cpuTopBars when you log in.
* **How to Read the Menu Bar:** a window, opened from the menu, that explains the bars and their colours, with drawn examples.
* **Support Team Fox:** a menu row that opens halfmarble's Team Fox fundraising page in your browser.
* **Customizable:** Settings opens with a Demo group that previews the menu-bar graph live, on a sine wave and on a flat wave.
    * **Refresh Rates:** Choose between 2, 5, or 10 updates per second for ultra-responsive feedback (5 by default).
    * **Top Processes:** Show 3, 5, 10 or 15 processes in the menu (5 by default).
* **System Integration:** One-click access to the macOS native **Activity Monitor**.

## 🔎 Hover Labels

Rest the pointer on a bar for a second and its reading shows below the menu bar.

* **Disk:** the startup volume's use, with its free and used space.

<img src="screenshots/hover-disk.png" width="370" alt="Disk usage label">

* **Memory:** memory in use, with free, used and swapped memory.

<img src="screenshots/hover-memory.png" width="502" alt="Memory usage label">

* **CPU:** overall CPU use, with the efficiency and performance cores' use.

<img src="screenshots/hover-cpu.png" width="436" alt="CPU label">

* **GPU:** the GPU's use.

<img src="screenshots/hover-gpu.png" width="153" alt="GPU label">

* **Neural Engine:** whether the Neural Engine is powered on.

<img src="screenshots/hover-neural-engine.png" width="174" alt="Neural Engine label">

* **Efficiency cores:** their use, then each efficiency core's load; › marks the core under the pointer.

<img src="screenshots/hover-e-cores.png" width="195" alt="Efficiency cores label">

* **Performance cores:** the same for the performance cores.

<img src="screenshots/hover-p-cores.png" width="218" alt="Performance cores label">

## 🛠 Installation

A Mac App Store release is coming. Until then, build it from source:

1.  Clone this repository and open `upMonitor.xcodeproj` in Xcode.
2.  Choose **Product > Run**.
3.  Look for the activity graph in your menu bar!

cpuTopBars requires macOS 27 or later.

cpuTopBars was called upMonitor; release 1.0 on GitHub is that old app. A copy you built from source under the old name keeps its own settings and its own login item, which still opens that copy at login: turn Launch at login off in the old copy, or delete it, then set your settings and Launch at login again in cpuTopBars, which starts with the default settings.

cpuTopBars runs in the App Sandbox. The sandbox gives an app no CPU figures for other users' processes (WindowServer, kernel_task, system daemons), so the menu lists your own processes and counts the others in one row.

## ⚙️ Configuration

To customize your experience:
1.  Click on the `cpuTopBars` icon in the menu bar.
2.  Select **Open cpuTopBars Settings...**
3.  Adjust the settings to fit your workflow.

## 🤝 Contributing

Contributions are welcome! Whether it's reporting a bug, suggesting a feature, or submitting a pull request, feel free to get involved.

1.  Fork the Project
2.  Create your Feature Branch (`git checkout -b feature/AmazingFeature`)
3.  Commit your Changes (`git commit -m 'Add some AmazingFeature'`)
4.  Push to the Branch (`git push origin feature/AmazingFeature`)
5.  Open a Pull Request

## 📄 License

Distributed under the MIT License. See `LICENSE` for more information.

---
Created with ❤️ by [halfmarble](https://github.com/halfmarble)

halfmarble pledges **5% of software net profits** to charity — 2.5% to [Team Fox](https://give.michaeljfox.org/halfmarble), the grassroots fundraising program of The Michael J. Fox Foundation, and 2.5% to [Public Health Collaboration](https://phcuk.org/) (PHC). halfmarble is an independent Team Fox third-party fundraiser.
