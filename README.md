[![License](https://img.shields.io/badge/Open%20Source-MIT-brightgreen.svg)](https://opensource.org/licenses/MIT)

# cpuTopBars

A lightweight CPU monitoring tool designed specifically for the macOS menu bar. Keep a pulse on your system performance without cluttering your workspace.

* **hiding in the menu bar:**

![cpuTopBars Screenshot](Screenshot-menu.png)

* **showing settings, readings and processes:**

![cpuTopBars Screenshot](Screenshot-menu-preferences.png)

## 🚀 Features

`cpuTopBars` provides real-time insights into your system's CPU usage with a focus on aesthetics and customization.

* **Real-time Menu Bar Visualization:** View your CPU activity at a glance with a live-updating graph right in your macOS menu bar, beside small bars, in this order, for the battery (on a Mac with one: its charge as a number, then a bar filled to it, green while it charges), the Wi-Fi signal, disk and memory use, then after a small gap the Neural Engine (its busy share in the version built from this repository, whether it is powered on in the App Store versions), GPU use and overall CPU use, then bars for the efficiency cores' and the performance cores' use, each of these two heading its own cores' bars when the graph shows each core and the Mac lists its efficiency cores first (switchable in Settings, the battery and Wi-Fi bars with a switch of their own).
* **Top Process Tracking:** Quickly identify which of your processes are consuming the most CPU with a ranked list of processes, titled "TOP PROCESSES BY CPU" in the version built from this repository and "YOUR TOP PROCESSES BY CPU" in the App Store versions, each with its CPU share and its memory (physical footprint, in GB); in the version built from this repository the list ranks other users' processes too, among them macOS's system daemons and WindowServer, while it is sorted by CPU; sorted by memory, and in the App Store versions, they are counted in one row below it.
* **System readings:** when the menu opens, a panel beside it shows uptime, the battery's charge and whether it is charging, Wi-Fi's state and, while connected, the details the macOS Wi-Fi menu shows with the Option key held (IP address, router, MAC address, security, channel, signal, noise, transmit rate and PHY mode; not the network's name, so no Location Services permission is asked), then startup-volume, memory and overall CPU usage as percentages with their sizes, the disk and memory with their free and used space, memory with its swap in use and CPU with its efficiency and performance cores' use, GPU use (with its power in watts in the version built from this repository) and the Neural Engine's busy share (in the App Store versions, whether it is powered on), all read on the Mac; nothing is sent over the network.
* **Hover labels:** rest the pointer on a bar for a second to see its value below the menu bar; on the core bars it lists each core's load.
* **Process inspector:** click a process in the menu to open a window with its man page, where it has one, and its arguments and environment; in the version built from this repository also its open files (lsof), its symbols (nm) and a sample of its stacks (sample), and a Kill button for your own processes.
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

* **Neural Engine:** the Neural Engine's busy share (in the App Store versions, whether it is powered on).

<img src="screenshots/hover-neural-engine.png" width="174" alt="Neural Engine label">

* **Efficiency cores:** their use, then each efficiency core's load; › marks the core under the pointer.

<img src="screenshots/hover-e-cores.png" width="195" alt="Efficiency cores label">

* **Performance cores:** the same for the performance cores.

<img src="screenshots/hover-p-cores.png" width="218" alt="Performance cores label">

## 🛠 Installation

A Mac App Store release is coming. Until then, build it from source:

1.  Clone this repository and open `cpuTopBars.xcodeproj` in Xcode.
2.  Choose **Product > Run**.
3.  Look for the activity graph in your menu bar!

cpuTopBars requires macOS 27 or later.

cpuTopBars was called upMonitor; release 1.0 on GitHub is that old app. A copy you built from source under the old name keeps its own settings and its own login item, which still opens that copy at login: turn Launch at login off in the old copy, or delete it, then set your settings and Launch at login again in cpuTopBars, which starts with the default settings.

The version you build from this repository runs outside the App Sandbox. Sorted by CPU, it ranks every user's processes (WindowServer, kernel_task, system daemons) in the list; it gives the inspector lsof, nm and sample tabs and a Kill button for your own processes, and shows the Neural Engine's busy share and the GPU's power in watts. The App Store versions are sandboxed: the sandbox gives an app no CPU figures for other users' processes and does not let it run those tools or signal other processes, and the counters behind the Neural Engine's share and the GPU's watts are left out of those versions. So they list your own processes, count the others in one row, show no extra inspector tabs and no Kill button, and show the Neural Engine as on or off. The Neural Engine's share and the GPU's watts come from counters Apple does not document; they were checked on one Mac (an M3), and where they cannot be read the Neural Engine shows on or off and the GPU shows its use alone.

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
