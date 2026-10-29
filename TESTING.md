# Testing XM6-Connect

## Automated tests

```sh
bash scripts/run_tests.sh
```

This builds the package in debug mode and runs the `KitTests` suite. The suite needs no
headphones, no Bluetooth permission, and no installed app. The device, the clock, the timers and
`launchctl` are all fakes inside the suite. Each test prints `PASS <name>` or `FAIL <name>`, and
the last line is a summary:

```text
TOTAL <n> FAIL 0
```

The command exits with a non-zero status if any test fails. CI (`.github/workflows/test.yml`) runs
the same script and also checks that this summary line ends in `FAIL 0`.

## Manual hardware checklist

Before a release, or after you change Bluetooth, lease, IPC, widget or install code, walk through
this list with a real WH-1000XM6 that is paired and connected to the Mac. Building `xm6ctl` first
makes steps 6 and 7 easier:

```sh
swift build -c release --product xm6ctl
```

The steps below use `.build/release/xm6ctl`.

1. **Install.** Run `bash scripts/install.sh`. It should end without errors, and then:
   - `~/Applications/XM6-Connect.app` exists;
   - the headphones icon appears in the menu bar;
   - `~/Library/LaunchAgents` contains `io.github.mbieniooo.xm6connect.agent.plist` and
     `io.github.mbieniooo.xm6connect.login.plist`.

2. **Permission.** The first time the agent connects, macOS asks for Bluetooth access. Allow it.
   Then rebuild an ad-hoc-signed copy and install it again. You should get the prompt again. If you
   set `CODESIGN_IDENTITY` to a real identity, you should not get it again.

3. **Popover.**
   - Open the popover. After a moment it should show the headphones' current settings.
   - Change each control in turn: noise-control mode, ambient level (only enabled in Ambient), Focus
     on voice, listening mode, room size (only enabled in Background Music), EQ preset, the ten
     Custom bands (only enabled on Custom), speak-to-chat, and the multipoint playback source.
   - After each change, check that the headphones really changed: listen, or look in Sony's app
     afterwards.
   - Check that each control keeps showing your new value until the headphones confirm it, and
     does not jump back to the old value in between.
   - Battery level and charging state should match the headphones.

4. **Widget.** Add the XM6-Connect desktop widget in both sizes.
   - The NC / Ambient / Off buttons should change the mode.
   - On the medium widget, the preset buttons should change the EQ.
   - The popover should show each change.
   - Quit the agent, or take the headphones out of range. Once the last state is more than 20
     minutes old, or after a failed connection attempt, the widget should dim and show a clock badge.

5. **xm6ctl.**
   - Run `status` and `status --json`.
   - Run each verb once: `refresh`, `mode nc|ambient|off`, `cycle`, `ambient 10`, `focus on|off`,
     `listening standard|bgm|cinema`, `bgm-room small|middle|large`, `eq preset clear`,
     `eq bands 0 1 2 3 4 5 6 -6 0 0`, `stc on|off`, `playback <device name>` and `reconnect`.
   - Check that each one exits with `0` and that the change shows in the popover.
   - Check the error exit codes:
     - `xm6ctl mode loud` and `xm6ctl ambient 21` exit with `64` and print the usage line.
     - `xm6ctl playback no-such-device` exits with `1` and prints `unknown playback device`.
     - With the agent stopped, every verb exits with `1` and prints
       `XM6ConnectAgent is not running or did not reply within 5 seconds`. To stop the agent:
       ```sh
       launchctl bootout gui/$(id -u)/io.github.mbieniooo.xm6connect.agent
       ```
       Restart it afterwards with **Start agent** in the popover, or by running `install.sh` again.

6. **Phone handoff.**
   - Change a setting on the Mac and wait about 30 seconds. `xm6ctl status` should show
     `ownership: released`. Sony's phone app should then connect and work normally.
   - While the phone app is connected, change a setting on the Mac. The popover should report that
     control was yielded, and the phone app should stay connected.
   - Run `xm6ctl yield 60`, then `xm6ctl hold on` and `xm6ctl hold off`. With hold on, the phone app
     should be unable to connect. After hold off, it should be able to connect again within about
     20 seconds.

7. **Start at login.**
   - With **Start XM6-Connect at login** on, log out and back in. The agent should be running and
     the menu-bar icon should come back.
   - Note the agent's process ID (`pgrep -x XM6ConnectAgent`), then turn the toggle off.
   - Both LaunchAgent plists should be gone, and the agent should keep running with the same process
     ID until you log out.
   - Turn the toggle on again. Both plists should be back.

8. **Uninstall.**
   - Run `bash scripts/uninstall.sh`. The app, both LaunchAgents and the running processes should
     be gone, and `~/Library/Application Support/XM6Connect` should still exist.
   - Run `bash scripts/uninstall.sh --purge`. That folder should be removed as well.
