//
// Copyright (C) 2026 Plank Reloaded Developers
//
// This file is part of Plank.
//
// Plank is free software: you can redistribute it and/or modify
// it under the terms of the GNU General Public License as published by
// the Free Software Foundation, either version 3 of the License, or
// (at your option) any later version.
//
// Plank is distributed in the hope that it will be useful,
// but WITHOUT ANY WARRANTY; without even the implied warranty of
// MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the
// GNU General Public License for more details.
//
// You should have received a copy of the GNU General Public License
// along with this program.  If not, see <http://www.gnu.org/licenses/>.
//

namespace Plank {

  /**
   * MonitorManager supervises one plank dock child process per connected
   * monitor.  It is launched with `plank --monitor-manager`
   * and stays alive for the lifetime of the session, spawning or terminating
   * child processes as monitors are hotplugged or unplugged.
   *
   * Each child is launched as:
   *   plank -n <monitor-name> --assigned-monitor <monitor-name>
   *
   * The instance name (-n) binds the dock to a named GSettings sub-path so
   * preferences are persisted per monitor.  The --assigned-monitor argument tells
   * the dock which physical output to target on first launch (before it has
   * had a chance to save that preference itself).
   *
   * Implementation note: We deliberately use a bare GLib.MainLoop rather than
   * GLib.Application / Gtk.Application.  This keeps the manager process
   * lightweight (no D-Bus name, no GTK windows) while still receiving GDK
   * display events via the GLib event loop that Gtk.init() installs.
   */
  public class MonitorManager : GLib.Object {

    // Map of monitor name → child PID.
    Gee.HashMap<string, Pid> children = new Gee.HashMap<string, Pid> ();

    // Absolute path to our own executable so children can be spawned
    // without depending on PATH.
    string self_exe;

    // The main loop we spin in run().
    GLib.MainLoop loop;

    // ── Public entry point ─────────────────────────────────────────────────

    /**
     * Initialise GTK, connect to the display, spawn initial children, install
     * signal handlers, then block in the main loop until asked to quit.
     *
     * @param args  The original argv (minus the --monitor-manager
     *              flag) so GTK can consume its own options.
     * @return      Exit status (0 = clean exit).
     */
    public int run (string[] args) {
      // Initialise GTK so GDK display infrastructure (and monitor signals)
      // is available.  We pass args so GTK can strip its own flags.
      Gtk.init (ref args);

      self_exe  = resolve_self_exe ();
      loop      = new GLib.MainLoop ();

      message ("Plank monitor manager starting (exe: %s)", self_exe);

      unowned Gdk.Display? display = Gdk.Display.get_default ();
      if (display == null) {
        critical ("Could not open a display — is DISPLAY set?");
        return 1;
      }

      // Connect before scanning so we cannot miss an event that arrives
      // between the initial scan and the signal connection.
      display.monitor_added.connect   (on_monitor_added);
      display.monitor_removed.connect (on_monitor_removed);

      // Spawn one child per monitor that is already connected.
      int n = display.get_n_monitors ();
      for (int i = 0; i < n; i++)
        spawn_child_for_monitor (display.get_monitor (i), i);

      // Handle SIGTERM / SIGINT gracefully.
      Unix.signal_add (Posix.Signal.TERM, on_signal);
      Unix.signal_add (Posix.Signal.INT,  on_signal);

      // Block here until loop.quit() is called.
      loop.run ();

      // Clean up before returning to main().
      display.monitor_added.disconnect   (on_monitor_added);
      display.monitor_removed.disconnect (on_monitor_removed);
      request_all_children_exit ();

      message ("Plank monitor manager stopped.");
      return 0;
    }

    // ── GDK monitor hotplug callbacks ──────────────────────────────────────

    void on_monitor_added (Gdk.Display display, Gdk.Monitor monitor) {
      int index = find_monitor_index (display, monitor);
      string name = get_monitor_name (monitor, index);
      message ("Monitor connected: %s (index %d)", name, index);
      spawn_child_for_monitor (monitor, index);
    }

    void on_monitor_removed (Gdk.Display display, Gdk.Monitor monitor) {
      // At this point GDK has already removed the monitor from its list, so
      // we cannot look up its index.  Match by the model string we stored
      // when the child was spawned.
      string? name = name_for_removed_monitor (monitor);
      if (name == null) {
        warning ("Removed monitor has no matching child — ignoring.");
        return;
      }
      message ("Monitor disconnected: %s", name);
      request_child_exit (name);
    }

    // ── Signal handler ─────────────────────────────────────────────────────

    bool on_signal () {
      message ("Monitor manager received termination signal — quitting.");
      loop.quit ();
      return GLib.Source.REMOVE;
    }

    // ── Child lifecycle ────────────────────────────────────────────────────

    /**
     * Spawn a plank instance for the given monitor unless one is already
     * running for that monitor name.
     */
    void spawn_child_for_monitor (Gdk.Monitor monitor, int index) {
      string name = get_monitor_name (monitor, index);

      if (children.has_key (name)) {
        debug ("Child already running for '%s' — skipping.", name);
        return;
      }

      // -n <n>                 — dock instance name (GSettings sub-path)
      // --assigned-monitor <n> — internal: the physical output this instance
      //                          is assigned to; applied only if the dock's
      //                          saved Monitor preference is still unset
      string[] argv = {
        self_exe,
        "-n",                 name,
        "--assigned-monitor", name,
      };

      Pid pid;
      try {
        Process.spawn_async (
          null,   // inherit working directory
          argv,
          null,   // inherit environment
          SpawnFlags.SEARCH_PATH | SpawnFlags.DO_NOT_REAP_CHILD,
          null,   // no child setup function
          out pid
        );
      } catch (SpawnError e) {
        warning ("Failed to spawn plank for monitor '%s': %s", name, e.message);
        return;
      }

      message ("Spawned plank for monitor '%s' (PID %d)", name, (int) pid);
      children[name] = pid;

      // Watch the child so we can clean up the map when it exits on its own.
      ChildWatch.add (pid, (p, status) => {
        on_child_exited (name, p, status);
      });
    }

    /**
     * Ask the child dock for the named monitor to exit cleanly by sending
     * SIGTERM.  This is the standard Unix "please shut down gracefully"
     * signal — the dock's own signal handler calls GLib.Application.quit(),
     * which runs the normal GTK teardown path (saving preferences, cleaning
     * up resources, etc.) before the process exits.  SIGKILL is deliberately
     * not used here; we want the dock to close on its own terms.
     *
     * The map entry is removed immediately so no further actions are taken
     * for this monitor.  Process.close_pid() is called later by the
     * ChildWatch callback once the process has actually exited.
     */
    void request_child_exit (string name) {
      if (!children.has_key (name)) {
        debug ("No child for '%s' to request exit from.", name);
        return;
      }

      Pid pid = children[name];
      message ("Asking plank for monitor '%s' (PID %d) to exit gracefully.", name, (int) pid);
      Posix.kill ((Posix.pid_t) pid, Posix.Signal.TERM);
      children.unset (name);
    }

    /** Ask every running child to exit gracefully (called on manager shutdown). */
    void request_all_children_exit () {
      // Copy keys to avoid modifying the map while iterating.
      var names = new Gee.ArrayList<string> ();
      names.add_all (children.keys);
      foreach (var name in names)
        request_child_exit (name);
    }

    /**
     * Called by GLib when a watched child process exits — either because we
     * asked it to via SIGTERM, or because the user closed the dock manually.
     *
     * If this was the last child and the manager is still running (i.e. we
     * did not initiate a full shutdown ourselves), we quit the main loop so
     * the manager process does not linger uselessly with no docks to supervise.
     */
    void on_child_exited (string name, Pid pid, int status) {
      Process.close_pid (pid);

      // Only remove if the PID still matches — request_child_exit() may have
      // already removed the entry.
      if (children.has_key (name) && children[name] == pid)
        children.unset (name);

      if (Process.if_exited (status))
        message ("Plank for '%s' (PID %d) exited (code %d).",
                 name, (int) pid, Process.exit_status (status));
      else
        message ("Plank for '%s' (PID %d) exited via signal.", name, (int) pid);

      // If the last child is gone, quit cleanly — nothing left to supervise.
      // loop.quit() is safe to call even if the loop is not currently running.
      debug ("Children remaining after exit of '%s': %d", name, children.size);
      if (children.is_empty) {
        message ("All dock instances have exited — monitor manager shutting down.");
        loop.quit ();
      }
    }

    // ── Helpers ────────────────────────────────────────────────────────────

    /**
     * Canonical name for a monitor: GDK model string, or a stable fallback.
     * Must match PositionManager.get_monitor_name() exactly.
     */
    static string get_monitor_name (Gdk.Monitor monitor, int index) {
      return monitor.get_model () ?? "PLUG_MONITOR_%i".printf (index);
    }

    /** Return the index of a monitor in the current display list. */
    static int find_monitor_index (Gdk.Display display, Gdk.Monitor target) {
      int n = display.get_n_monitors ();
      for (int i = 0; i < n; i++)
        if (display.get_monitor (i) == target)
          return i;
      return 0;
    }

    /**
     * Reverse-lookup: find the children-map key for a monitor that has just
     * been removed (and is therefore no longer in the display list).
     * We match on the Gdk.Monitor object's model string.
     */
    string? name_for_removed_monitor (Gdk.Monitor monitor) {
      string? model = monitor.get_model ();
      if (model != null && children.has_key (model))
        return model;

      // PLUG_MONITOR_N fallback: if exactly one such key is in the map we
      // can identify it unambiguously.
      string? found = null;
      int count = 0;
      foreach (var key in children.keys) {
        if (key.has_prefix ("PLUG_MONITOR_")) {
          found = key;
          count++;
        }
      }
      return (count == 1) ? found : null;
    }

    /** Resolve the absolute path to this executable via /proc/self/exe. */
    static string resolve_self_exe () {
      try {
        return GLib.FileUtils.read_link ("/proc/self/exe");
      } catch (FileError e) {
        warning ("Could not resolve self exe: %s — falling back to 'plank'.", e.message);
        return "plank";
      }
    }
  }
}
