[![License](https://img.shields.io/badge/Open%20Source-MIT-brightgreen.svg)](https://opensource.org/licenses/MIT)

# upMonitor

A lightweight, highly customizable CPU monitoring tool designed specifically for the macOS menu bar. Keep a pulse on your system performance without cluttering your workspace.

* **hiding in the menu bar:**

![upMonitor Screenshot](Screenshot-menu.png)

* **showing preferences, readings and processes:**

![upMonitor Screenshot](Screenshot-menu-preferences.png)

## 🚀 Features

`upMonitor` provides real-time insights into your system's CPU usage with a focus on aesthetics and customization.

* **Real-time Menu Bar Visualization:** View your CPU activity at a glance with a live-updating graph right in your macOS menu bar, beside three small bars for disk, memory and overall CPU use (switchable in Preferences).
* **Top Process Tracking:** Quickly identify which of your processes are consuming the most CPU with a ranked list of "Your Top Processes by CPU"; processes of other users, among them macOS's system daemons and WindowServer, are counted in one row below it.
* **System readings:** when the menu opens, a panel beside it shows uptime, then startup-volume, memory and overall CPU usage as percentages with their sizes, all read on the Mac; nothing is sent over the network.
* **Freeze:** pause the process list to examine it while the CPU graph keeps running; while frozen, rest on a ↳ row to see what it is a helper of.
* **Launch at login:** tick it in Preferences to open upMonitor when you log in.
* **Highly Customizable:**
    * **Granularity:** Monitor at the Package, Core, or Logical Processor level.
    * **Refresh Rates:** Choose between 2, 5, or 10 updates per second for ultra-responsive feedback.
    * **Visual Styles:** Switch between Bar and Dot styles to match your preference.
    * **Appearance:** Choose from various color themes (including vibrant gradients) or a classic grey look.
    * **Line Weights:** Adjust thickness and choose between solid or dashed lines.
    * **Top Processes:** Show 3, 5, 10 or 15 processes in the menu (15 by default).
* **System Integration:** One-click access to the macOS native **Activity Monitor**.

## 🛠 Installation

1.  Download the latest release from the [Releases](https://github.com/halfmarble/upMonitor/releases) page.
2.  Drag `upMonitor.app` to your `/Applications` folder.
3.  Launch the app and look for the activity graph in your menu bar!

upMonitor requires macOS 27 or later.

upMonitor runs in the App Sandbox. The sandbox gives an app no CPU figures for other users' processes (WindowServer, kernel_task, system daemons), so the menu lists your own processes and counts the others in one row.

## ⚙️ Configuration

To customize your experience:
1.  Click on the `upMonitor` icon in the menu bar.
2.  Select **Open upMonitor Preferences...**
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

halfmarble pledges **5% of software net profits** to charity — 2.5% to Team Fox, the grassroots fundraising program of The Michael J. Fox Foundation, and 2.5% to [Public Health Collaboration](https://phcuk.org/) (PHC). halfmarble is an independent Team Fox third-party fundraiser.
