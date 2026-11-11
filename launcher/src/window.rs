// SPDX-License-Identifier: GPL-3.0-or-later
//! The launcher window: Play, Host, Mods and Settings pages.

use crate::assets;
use crate::config::Config;
use crate::scan::{self, Kind};
use crate::APP_ID;
use adw::prelude::*;
use gtk::{gio, glib};
use std::cell::{Cell, RefCell};
use std::ffi::OsString;
use std::rc::Rc;

struct State {
    cfg: RefCell<Config>,
    server: RefCell<Option<gio::Subprocess>>,
    /// Called when the game directory changed (rescan maps, mods, binaries).
    game_changed: RefCell<Vec<Box<dyn Fn()>>>,
}

type Shared = Rc<State>;

const PRESETS: [&str; 4] = ["1280x720", "1600x900", "1920x1080", "2560x1440"];

pub fn build(app: &adw::Application) -> adw::ApplicationWindow {
    let state: Shared = Rc::new(State {
        cfg: RefCell::new(Config::load()),
        server: RefCell::new(None),
        game_changed: RefCell::new(Vec::new()),
    });

    let toasts = adw::ToastOverlay::new();
    let banner = adw::Banner::new("");
    banner.set_button_label(Some("Open Settings"));

    let assets_banner = adw::Banner::new("The Xonotic game assets (maps, textures, sounds) are missing.");
    assets_banner.set_button_label(Some("Set Up…"));

    let stack = adw::ViewStack::new();
    let play = build_play(&state, &toasts, &stack);
    let host = build_host(&state, &toasts);
    let mods = build_mods(&state, &toasts);
    let settings = build_settings(&state);
    stack.add_titled_with_icon(&play, Some("play"), "Play", "media-playback-start-symbolic");
    stack.add_titled_with_icon(&host, Some("host"), "Host", "network-server-symbolic");
    stack.add_titled_with_icon(&mods, Some("mods"), "Mods", "application-x-addon-symbolic");
    stack.add_titled_with_icon(&settings, Some("settings"), "Settings", "emblem-system-symbolic");

    stack.set_visible_child_name("play");
    let switcher = adw::ViewSwitcher::builder()
        .stack(&stack)
        .policy(adw::ViewSwitcherPolicy::Wide)
        .build();
    let bar = adw::ViewSwitcherBar::builder().stack(&stack).build();

    let menu = gio::Menu::new();
    menu.append(Some("About Insanotic"), Some("app.about"));
    menu.append(Some("Quit"), Some("app.quit"));
    let menu_button = gtk::MenuButton::builder()
        .icon_name("open-menu-symbolic")
        .menu_model(&menu)
        .primary(true)
        .tooltip_text("Main Menu")
        .build();
    let header = adw::HeaderBar::new();
    header.set_title_widget(Some(&switcher));
    header.pack_end(&menu_button);

    let view = adw::ToolbarView::new();
    view.add_top_bar(&header);
    view.add_top_bar(&banner);
    view.add_top_bar(&assets_banner);
    view.add_bottom_bar(&bar);
    toasts.set_child(Some(&stack));
    view.set_content(Some(&toasts));

    let win = adw::ApplicationWindow::builder()
        .application(app)
        .title("Insanotic")
        .default_width(760)
        .default_height(700)
        .width_request(360)
        .content(&view)
        .build();

    // narrow windows: view switcher moves to the bottom bar
    let bp = adw::Breakpoint::new(adw::BreakpointCondition::parse("max-width: 600sp").unwrap());
    bp.add_setter(&switcher, "visible", Some(&false.to_value()));
    bp.add_setter(&bar, "reveal", Some(&true.to_value()));
    win.add_breakpoint(bp);

    // banner when the engine binaries are missing
    {
        let st = state.clone();
        let banner = banner.clone();
        let check = move || {
            let game = st.cfg.borrow().game_dir();
            let missing = !game.join("darkplaces/darkplaces-sdl").is_file()
                || !game.join("darkplaces/darkplaces-dedicated").is_file();
            banner.set_title(&format!(
                "Game binaries not found in {}. Build them with make, or set the game directory.",
                game.display()
            ));
            banner.set_revealed(missing);
        };
        check();
        let check = Rc::new(check);
        // the binaries appear after a build: look again when the window is focused
        let c = check.clone();
        win.connect_is_active_notify(move |w| {
            if w.is_active() {
                c();
            }
        });
        state.game_changed.borrow_mut().push(Box::new(move || check()));
    }
    {
        let stack = stack.clone();
        banner.connect_button_clicked(move |_| stack.set_visible_child_name("settings"));
    }

    // game assets: offer to link or download them when missing
    {
        let busy = Rc::new(Cell::new(false));
        let st = state.clone();
        let ab = assets_banner.clone();
        let b = busy.clone();
        let check = Rc::new(move || {
            let game = st.cfg.borrow().game_dir();
            ab.set_revealed(b.get() || !assets::assets_present(&game));
        });
        check();
        let c = check.clone();
        win.connect_is_active_notify(move |w| {
            if w.is_active() {
                c();
            }
        });
        state.game_changed.borrow_mut().push(Box::new({
            let check = check.clone();
            move || check()
        }));
        let (st, t, b) = (state.clone(), toasts.clone(), busy);
        assets_banner.connect_button_clicked(move |banner| setup_assets(&st, &t, banner, b.clone()));
    }

    // stop our server when the window closes
    {
        let state = state.clone();
        win.connect_close_request(move |_| {
            if let Some(sub) = state.server.borrow().as_ref() {
                sub.force_exit();
            }
            state.cfg.borrow().save();
            glib::Propagation::Proceed
        });
    }
    win
}

// ---------------------------------------------------------------- helpers

fn run_game_changed(state: &Shared) {
    for f in state.game_changed.borrow().iter() {
        f();
    }
}

fn mb(bytes: u64) -> u64 {
    bytes / 1_000_000
}

/// Offers to link the assets of an installed Xonotic, or to download them.
fn setup_assets(state: &Shared, toasts: &adw::ToastOverlay, banner: &adw::Banner, busy: Rc<Cell<bool>>) {
    let found = assets::find_installed();
    let dialog = adw::AlertDialog::new(
        Some("Game Assets Needed"),
        Some("Insanotic uses the maps, textures and sounds of Xonotic 0.8.6. Link an installed copy, or download the official release (1.2 GB)."),
    );
    dialog.add_responses(&[("cancel", "_Cancel"), ("link", "_Use Installed Xonotic"), ("download", "_Download")]);
    dialog.set_response_enabled("link", found.is_some());
    dialog.set_response_appearance("download", adw::ResponseAppearance::Suggested);
    dialog.set_default_response(Some("download"));
    dialog.set_close_response("cancel");
    let (state, toasts, banner2) = (state.clone(), toasts.clone(), banner.clone());
    dialog.connect_response(None, move |_, id| {
        let game = state.cfg.borrow().game_dir();
        match id {
            "link" => {
                let Some(src) = found.clone() else { return };
                match assets::link_installed(&src, &game) {
                    Ok(()) => {
                        toast(&toasts, "Game assets linked");
                        run_game_changed(&state);
                    }
                    Err(e) => toast(&toasts, &format!("Could not link the assets: {e}")),
                }
            }
            "download" => {
                busy.set(true);
                let progress = std::sync::Arc::new(assets::Progress::default());
                banner2.set_button_label(None);
                banner2.set_title("Starting the download…");
                let (p, b, bn) = (progress.clone(), busy.clone(), banner2.clone());
                glib::timeout_add_local(std::time::Duration::from_millis(500), move || {
                    if !b.get() {
                        return glib::ControlFlow::Break;
                    }
                    use std::sync::atomic::Ordering::Relaxed;
                    let total = p.total.load(Relaxed);
                    if p.stage.load(Relaxed) == 0 {
                        bn.set_title(&format!(
                            "Downloading Xonotic game assets: {} of {} MB",
                            mb(assets::partial_size()),
                            mb(total)
                        ));
                    } else {
                        bn.set_title(&format!("Unpacking game assets: {} of {} MB", mb(p.done.load(Relaxed)), mb(total)));
                    }
                    glib::ControlFlow::Continue
                });
                let (state, toasts, banner3, busy) = (state.clone(), toasts.clone(), banner2.clone(), busy.clone());
                glib::spawn_future_local(async move {
                    let result = gio::spawn_blocking(move || assets::download(&game, progress)).await;
                    busy.set(false);
                    banner3.set_title("The Xonotic game assets (maps, textures, sounds) are missing.");
                    banner3.set_button_label(Some("Set Up…"));
                    match result {
                        Ok(Ok(())) => toast(&toasts, "Game assets ready"),
                        Ok(Err(e)) => toast(&toasts, &e),
                        Err(_) => toast(&toasts, "The download stopped unexpectedly."),
                    }
                    run_game_changed(&state);
                });
            }
            _ => {}
        }
    });
    dialog.present(Some(banner));
}

fn toast(toasts: &adw::ToastOverlay, msg: &str) {
    toasts.add_toast(adw::Toast::new(msg));
}

fn split_args(text: &str) -> Result<Vec<String>, String> {
    if text.trim().is_empty() {
        return Ok(Vec::new());
    }
    glib::shell_parse_argv(text)
        .map(|v| v.into_iter().map(|s| s.to_string_lossy().into_owned()).collect())
        .map_err(|e| format!("Cannot parse the extra arguments: {e}"))
}

/// Starts the game client, optionally connecting to a server.
fn start_client(state: &Shared, toasts: &adw::ToastOverlay, connect: Option<&str>, on_exit: impl Fn() + 'static) {
    let cfg = state.cfg.borrow().clone();
    let game = cfg.game_dir();
    let bin = game.join("darkplaces/darkplaces-sdl");
    if !bin.is_file() {
        toast(toasts, &format!("Game client not found: {}", bin.display()));
        on_exit();
        return;
    }
    let extra = match split_args(&cfg.extra_args) {
        Ok(v) => v,
        Err(e) => {
            toast(toasts, &e);
            on_exit();
            return;
        }
    };
    let mut args: Vec<String> = vec![bin.to_string_lossy().into_owned(), "-xonotic".into()];
    args.push(if cfg.fullscreen { "-fullscreen" } else { "-window" }.into());
    let size = match cfg.resolution.split_once('x') {
        Some((w, h)) => Some((w.to_string(), h.to_string())),
        None => None, // native: the engine uses the desktop size
    };
    if let Some((w, h)) = size {
        args.extend(["+vid_width".into(), w, "+vid_height".into(), h]);
    }
    args.extend(["+set".into(), "cl_lua_disabled".into(), cfg.disabled_mods.join(" ")]);
    args.extend(["+set".into(), "aim_assist_mode".into(), cfg.aim_assist_mode.to_string()]);
    args.extend([
        "+set".into(),
        "touch_controls_force".into(),
        (cfg.touch_controls_force as u8).to_string(),
    ]);
    args.extend(extra);
    if let Some(addr) = connect {
        args.extend(["+connect".into(), addr.into()]);
    }
    let launcher = gio::SubprocessLauncher::new(gio::SubprocessFlags::NONE);
    launcher.set_cwd(&game);
    let argv: Vec<OsString> = args.iter().map(OsString::from).collect();
    let argv: Vec<&std::ffi::OsStr> = argv.iter().map(|s| s.as_os_str()).collect();
    match launcher.spawn(&argv) {
        Ok(sub) => {
            let toasts = toasts.clone();
            glib::spawn_future_local(async move {
                let _ = sub.wait_future().await;
                if !sub.is_successful() {
                    toast(&toasts, "The game exited with an error. Run it from a terminal for details.");
                }
                on_exit();
            });
        }
        Err(e) => {
            toast(toasts, &format!("Could not start the game: {e}"));
            on_exit();
        }
    }
}

fn combo(title: &str, items: &[&str]) -> adw::ComboRow {
    let row = adw::ComboRow::builder().title(title).build();
    row.set_model(Some(&gtk::StringList::new(items)));
    row
}

// ------------------------------------------------------------------- Play

fn build_play(state: &Shared, toasts: &adw::ToastOverlay, _stack: &adw::ViewStack) -> adw::PreferencesPage {
    let page = adw::PreferencesPage::new();

    let hero = adw::StatusPage::builder()
        .icon_name(APP_ID)
        .title("Insanotic")
        .description("Xonotic with Lua scripting")
        .build();
    hero.add_css_class("compact");
    let group = adw::PreferencesGroup::new();
    group.add(&hero);
    page.add(&group);

    let display = adw::PreferencesGroup::builder().title("Display").build();
    let mode = combo("Window Mode", &["Windowed", "Fullscreen"]);
    let mut res_items: Vec<String> = vec!["Native".to_string()];
    res_items.extend(PRESETS.iter().map(|p| p.replace('x', " × ")));
    let res_refs: Vec<&str> = res_items.iter().map(String::as_str).collect();
    let res = combo("Resolution", &res_refs);
    let extra = adw::EntryRow::builder().title("Extra Arguments").show_apply_button(true).build();
    display.add(&mode);
    display.add(&res);
    display.add(&extra);
    page.add(&display);

    {
        let cfg = state.cfg.borrow();
        mode.set_selected(cfg.fullscreen as u32);
        let idx = PRESETS.iter().position(|p| *p == cfg.resolution).map(|i| i as u32 + 1).unwrap_or(0);
        res.set_selected(idx);
        extra.set_text(&cfg.extra_args);
    }
    {
        let s = state.clone();
        mode.connect_selected_notify(move |r| {
            s.cfg.borrow_mut().fullscreen = r.selected() == 1;
            s.cfg.borrow().save();
        });
        let s = state.clone();
        res.connect_selected_notify(move |r| {
            let i = r.selected() as usize;
            s.cfg.borrow_mut().resolution = if i == 0 { "native".into() } else { PRESETS[i - 1].into() };
            s.cfg.borrow().save();
        });
        let s = state.clone();
        extra.connect_apply(move |e| {
            s.cfg.borrow_mut().extra_args = e.text().to_string();
            s.cfg.borrow().save();
        });
    }

    let go = adw::PreferencesGroup::new();
    let button = gtk::Button::builder().label("Play").halign(gtk::Align::Center).build();
    button.add_css_class("suggested-action");
    button.add_css_class("pill");
    go.add(&button);
    page.add(&go);
    {
        let state = state.clone();
        let toasts = toasts.clone();
        button.connect_clicked(move |b| {
            b.set_sensitive(false);
            let b2 = b.clone();
            start_client(&state, &toasts, None, move || b2.set_sensitive(true));
        });
    }
    page
}

// ------------------------------------------------------------------- Host

fn strip_colors(line: &str) -> String {
    // Quake color codes: ^0-^9 and ^xRGB; also drop ANSI escapes
    let chars: Vec<char> = line.chars().collect();
    let mut out = String::new();
    let mut i = 0;
    while i < chars.len() {
        let c = chars[i];
        if c == '^' && i + 1 < chars.len() {
            if chars[i + 1].is_ascii_digit() {
                i += 2;
                continue;
            }
            if chars[i + 1] == 'x'
                && i + 4 < chars.len()
                && chars[i + 2..i + 5].iter().all(|c| c.is_ascii_hexdigit())
            {
                i += 5;
                continue;
            }
            if chars[i + 1] == '^' {
                out.push('^');
                i += 2;
                continue;
            }
        }
        if c == '\u{1b}' {
            i += 1;
            if i < chars.len() && chars[i] == '[' {
                while i < chars.len() && !chars[i].is_ascii_alphabetic() {
                    i += 1;
                }
                i += 1;
            }
            continue;
        }
        if c != '\r' {
            out.push(c);
        }
        i += 1;
    }
    out
}

/// Asks the server to quit on its console; terminates it if it does not.
fn stop_server(sub: &gio::Subprocess) {
    if let Some(stdin) = sub.stdin_pipe() {
        let _ = stdin.write_all(b"quit\n", gio::Cancellable::NONE);
        let _ = stdin.flush(gio::Cancellable::NONE);
    }
    let sub = sub.clone();
    glib::timeout_add_seconds_local_once(3, move || {
        sub.send_signal(15);
        let sub = sub.clone();
        glib::timeout_add_seconds_local_once(3, move || sub.force_exit());
    });
}

fn build_host(state: &Shared, toasts: &adw::ToastOverlay) -> adw::PreferencesPage {
    let page = adw::PreferencesPage::new();

    // controls
    let controls = adw::PreferencesGroup::builder().title("Local Server").build();
    let status = adw::ActionRow::builder().title("Dedicated Server").subtitle("Stopped").build();
    let join = gtk::Button::builder().label("Join").valign(gtk::Align::Center).sensitive(false).build();
    join.set_tooltip_text(Some("Start the game and connect to this server"));
    let toggle = gtk::Button::builder().label("Start").valign(gtk::Align::Center).build();
    toggle.add_css_class("suggested-action");
    status.add_suffix(&join);
    status.add_suffix(&toggle);
    controls.add(&status);
    page.add(&controls);

    // options
    let options = adw::PreferencesGroup::builder().title("Options").build();
    let map = adw::ComboRow::builder().title("Map").enable_search(true).build();
    map.set_expression(Some(&gtk::PropertyExpression::new(
        gtk::StringObject::static_type(),
        None::<gtk::Expression>,
        "string",
    )));
    let bots = adw::SpinRow::with_range(0.0, 32.0, 1.0);
    bots.set_title("Bots");
    let port = adw::SpinRow::with_range(1024.0, 65535.0, 1.0);
    port.set_title("Port");
    let plugins = adw::SwitchRow::builder()
        .title("Server Plugins")
        .subtitle("Run Lua plugins (g_lua)")
        .build();
    options.add(&map);
    options.add(&bots);
    options.add(&port);
    options.add(&plugins);
    page.add(&options);

    {
        let cfg = state.cfg.borrow();
        bots.set_value(cfg.bots as f64);
        port.set_value(cfg.port as f64);
        plugins.set_active(cfg.server_plugins);
    }
    let maps: Rc<RefCell<Vec<String>>> = Rc::new(RefCell::new(Vec::new()));
    let fill_maps = {
        let state = state.clone();
        let map = map.clone();
        let maps = maps.clone();
        move || {
            let game = state.cfg.borrow().game_dir();
            let list = scan::scan_maps(&game);
            let model = gtk::StringList::new(&list.iter().map(String::as_str).collect::<Vec<_>>());
            let wanted = state.cfg.borrow().map.clone();
            let idx = list
                .iter()
                .position(|m| *m == wanted)
                .or_else(|| list.iter().position(|m| m == "stormkeep"))
                .unwrap_or(0);
            map.set_model(Some(&model));
            map.set_selected(idx as u32);
            map.set_subtitle(&format!("{} available", list.len()));
            state.cfg.borrow_mut().map = list.get(idx).cloned().unwrap_or_default();
            *maps.borrow_mut() = list;
        }
    };
    fill_maps();
    state.game_changed.borrow_mut().push(Box::new(fill_maps));
    {
        let s = state.clone();
        let maps = maps.clone();
        map.connect_selected_notify(move |r| {
            if let Some(m) = maps.borrow().get(r.selected() as usize) {
                s.cfg.borrow_mut().map = m.clone();
                s.cfg.borrow().save();
            }
        });
        let s = state.clone();
        bots.connect_value_notify(move |r| {
            s.cfg.borrow_mut().bots = r.value() as u32;
            s.cfg.borrow().save();
        });
        let s = state.clone();
        port.connect_value_notify(move |r| {
            s.cfg.borrow_mut().port = r.value() as u32;
            s.cfg.borrow().save();
        });
        let s = state.clone();
        plugins.connect_active_notify(move |r| {
            s.cfg.borrow_mut().server_plugins = r.is_active();
            s.cfg.borrow().save();
        });
    }

    // server plugins
    let plugins_group = adw::PreferencesGroup::builder()
        .title("Server Plugins")
        .description("Lua plugins that run when server plugins are on.")
        .build();
    page.add(&plugins_group);
    let plugin_rows: Rc<RefCell<Vec<gtk::Widget>>> = Rc::new(RefCell::new(Vec::new()));
    let fill_plugins = {
        let state = state.clone();
        let group = plugins_group.clone();
        let rows = plugin_rows.clone();
        move || {
            for w in rows.borrow_mut().drain(..) {
                group.remove(&w);
            }
            let game = state.cfg.borrow().game_dir();
            let plugins = scan::scan_extensions(&game, Kind::Plugin);
            for e in &plugins {
                let row = adw::SwitchRow::builder()
                    .title(glib::markup_escape_text(&e.name).as_str())
                    .subtitle(glib::markup_escape_text(&describe(e)).as_str())
                    .active(!state.cfg.borrow().disabled_plugins.contains(&e.folder))
                    .build();
                let folder = e.folder.clone();
                let st = state.clone();
                row.connect_active_notify(move |r| {
                    let mut cfg = st.cfg.borrow_mut();
                    cfg.disabled_plugins.retain(|f| *f != folder);
                    if !r.is_active() {
                        cfg.disabled_plugins.push(folder.clone());
                    }
                    cfg.save();
                });
                group.add(&row);
                rows.borrow_mut().push(row.upcast());
            }
            if plugins.is_empty() {
                let row = adw::ActionRow::builder().title("No Server Plugins Found").build();
                row.add_css_class("dimmed");
                group.add(&row);
                rows.borrow_mut().push(row.upcast());
            }
        }
    };
    fill_plugins();
    state.game_changed.borrow_mut().push(Box::new(fill_plugins));

    // console
    let console = adw::PreferencesGroup::builder().title("Console").build();
    let buffer = gtk::TextBuffer::new(None);
    let view = gtk::TextView::builder()
        .buffer(&buffer)
        .editable(false)
        .cursor_visible(false)
        .monospace(true)
        .wrap_mode(gtk::WrapMode::WordChar)
        .left_margin(10)
        .right_margin(10)
        .top_margin(8)
        .bottom_margin(8)
        .build();
    view.update_property(&[gtk::accessible::Property::Label("Server console output")]);
    let scroll = gtk::ScrolledWindow::builder().child(&view).min_content_height(260).build();
    scroll.add_css_class("card");
    let end_mark = buffer.create_mark(Some("end"), &buffer.end_iter(), false);
    let cmd = adw::EntryRow::builder().title("Command").show_apply_button(true).sensitive(false).build();
    let cmd_list = gtk::ListBox::new();
    cmd_list.add_css_class("boxed-list");
    cmd_list.set_selection_mode(gtk::SelectionMode::None);
    cmd_list.append(&cmd);
    let console_box = gtk::Box::new(gtk::Orientation::Vertical, 12);
    console_box.append(&scroll);
    console_box.append(&cmd_list);
    console.add(&console_box);
    page.add(&console);

    let append = {
        let buffer = buffer.clone();
        let view = view.clone();
        move |text: &str| {
            buffer.insert(&mut buffer.end_iter(), text);
            if buffer.line_count() > 3000 {
                let mut start = buffer.start_iter();
                let mut end = buffer.iter_at_line(500).unwrap_or(buffer.end_iter());
                buffer.delete(&mut start, &mut end);
            }
            let (view, mark) = (view.clone(), end_mark.clone());
            glib::idle_add_local_once(move || {
                view.scroll_to_mark(&mark, 0.0, false, 0.0, 1.0);
            });
        }
    };
    let append = Rc::new(append);

    // UI state while the server runs
    let set_running = {
        let status = status.clone();
        let toggle = toggle.clone();
        let join = join.clone();
        let options = options.clone();
        let plugins_group = plugins_group.clone();
        let cmd = cmd.clone();
        move |running: bool, text: &str| {
            status.set_subtitle(text);
            options.set_sensitive(!running);
            plugins_group.set_sensitive(!running);
            join.set_sensitive(running);
            cmd.set_sensitive(running);
            toggle.set_label(if running { "Stop" } else { "Start" });
            toggle.remove_css_class(if running { "suggested-action" } else { "destructive-action" });
            toggle.add_css_class(if running { "destructive-action" } else { "suggested-action" });
        }
    };
    let set_running = Rc::new(set_running);

    {
        let state = state.clone();
        let toasts = toasts.clone();
        let append = append.clone();
        let set_running = set_running.clone();
        let buffer = buffer.clone();
        toggle.connect_clicked(move |_| {
            if let Some(sub) = state.server.borrow().clone() {
                stop_server(&sub);
                return;
            }
            let cfg = state.cfg.borrow().clone();
            let game = cfg.game_dir();
            let bin = game.join("darkplaces/darkplaces-dedicated");
            if !bin.is_file() {
                toast(&toasts, &format!("Dedicated server not found: {}", bin.display()));
                return;
            }
            if cfg.map.is_empty() {
                toast(&toasts, "No maps found. Check the game directory in Settings.");
                return;
            }
            let mut args: Vec<String> = vec![
                bin.to_string_lossy().into_owned(),
                "-xonotic".into(),
                "+exec".into(),
                "insanotic-server.cfg".into(),
                "+set".into(),
                "g_lua".into(),
                (cfg.server_plugins as u8).to_string(),
                "+set".into(),
                "sv_lua_disabled".into(),
                cfg.disabled_plugins.join(" "),
                "+port".into(),
                cfg.port.to_string(),
                "+set".into(),
                "bot_number".into(),
                cfg.bots.to_string(),
                "+map".into(),
                cfg.map.clone(),
            ];
            args.shrink_to_fit();
            let launcher = gio::SubprocessLauncher::new(
                gio::SubprocessFlags::STDOUT_PIPE
                    | gio::SubprocessFlags::STDERR_MERGE
                    | gio::SubprocessFlags::STDIN_PIPE,
            );
            launcher.set_cwd(&game);
            let argv: Vec<OsString> = args.iter().map(OsString::from).collect();
    let argv: Vec<&std::ffi::OsStr> = argv.iter().map(|s| s.as_os_str()).collect();
            let sub = match launcher.spawn(&argv) {
                Ok(s) => s,
                Err(e) => {
                    toast(&toasts, &format!("Could not start the server: {e}"));
                    return;
                }
            };
            buffer.set_text("");
            append(&format!("$ {}\n", args[1..].join(" ")));
            set_running(true, &format!("Running on port {}", cfg.port));
            *state.server.borrow_mut() = Some(sub.clone());

            let state = state.clone();
            let toasts = toasts.clone();
            let append = append.clone();
            let set_running = set_running.clone();
            glib::spawn_future_local(async move {
                if let Some(out) = sub.stdout_pipe() {
                    let reader = gio::DataInputStream::new(&out);
                    while let Ok(Some(line)) = reader.read_line_utf8_future(glib::Priority::DEFAULT).await {
                        append(&format!("{}\n", strip_colors(&line)));
                    }
                }
                let _ = sub.wait_future().await;
                let stopped_by_us = sub.has_signaled() && sub.term_sig() == 15;
                *state.server.borrow_mut() = None;
                set_running(false, "Stopped");
                if sub.is_successful() || stopped_by_us {
                    append("[server stopped]\n");
                } else {
                    append("[server exited with an error]\n");
                    toast(&toasts, "The server exited with an error. See the console.");
                }
            });
        });
    }

    {
        let state = state.clone();
        let toasts = toasts.clone();
        join.connect_clicked(move |b| {
            let addr = format!("localhost:{}", state.cfg.borrow().port);
            b.set_sensitive(false);
            let b2 = b.clone();
            let st = state.clone();
            start_client(&state, &toasts, Some(&addr), move || {
                b2.set_sensitive(st.server.borrow().is_some());
            });
        });
    }
    {
        let state = state.clone();
        let toasts = toasts.clone();
        let append = append.clone();
        cmd.connect_apply(move |row| {
            let text = row.text().to_string();
            if text.is_empty() {
                return;
            }
            let sub = state.server.borrow().clone();
            let Some(stdin) = sub.and_then(|s| s.stdin_pipe()) else { return };
            match stdin.write_all(format!("{text}\n").as_bytes(), gio::Cancellable::NONE) {
                Ok(_) => {
                    let _ = stdin.flush(gio::Cancellable::NONE);
                    append(&format!("> {text}\n"));
                    row.set_text("");
                }
                Err(e) => toast(&toasts, &format!("Could not send the command: {e}")),
            }
        });
    }
    page
}

// ------------------------------------------------------------------- Mods

fn describe(e: &scan::Extension) -> String {
    let mut head = e.origin.to_string();
    if !e.version.is_empty() {
        head = format!("Version {} · {}", e.version, e.origin);
    }
    if e.description.is_empty() {
        head
    } else {
        format!("{head}\n{}", e.description)
    }
}

fn build_mods(state: &Shared, toasts: &adw::ToastOverlay) -> adw::PreferencesPage {
    let page = adw::PreferencesPage::new();

    let mods_group = adw::PreferencesGroup::builder()
        .title("Client Mods")
        .description("Lua mods that run inside the game. Changes apply the next time you start the game.")
        .build();
    let refresh_btn = gtk::Button::builder().icon_name("view-refresh-symbolic").valign(gtk::Align::Center).build();
    refresh_btn.add_css_class("flat");
    refresh_btn.set_tooltip_text(Some("Rescan"));
    refresh_btn.update_property(&[gtk::accessible::Property::Label("Rescan mods and plugins")]);
    let open_btn = gtk::Button::builder().label("Open Mods Folder").valign(gtk::Align::Center).build();
    let header_box = gtk::Box::new(gtk::Orientation::Horizontal, 6);
    header_box.append(&refresh_btn);
    header_box.append(&open_btn);
    mods_group.set_header_suffix(Some(&header_box));
    page.add(&mods_group);

    let added: Rc<RefCell<Vec<(adw::PreferencesGroup, gtk::Widget)>>> = Rc::new(RefCell::new(Vec::new()));

    let rebuild = {
        let state = state.clone();
        let mods_group = mods_group.clone();
        let added = added.clone();
        move || {
            for (g, w) in added.borrow_mut().drain(..) {
                g.remove(&w);
            }
            let game = state.cfg.borrow().game_dir();
            let mods = scan::scan_extensions(&game, Kind::Mod);
            for e in &mods {
                let row = adw::SwitchRow::builder()
                    .title(glib::markup_escape_text(&e.name).as_str())
                    .subtitle(glib::markup_escape_text(&describe(e)).as_str())
                    .active(!state.cfg.borrow().disabled_mods.contains(&e.folder))
                    .build();
                let folder = e.folder.clone();
                let st = state.clone();
                row.connect_active_notify(move |r| {
                    let mut cfg = st.cfg.borrow_mut();
                    cfg.disabled_mods.retain(|f| *f != folder);
                    if !r.is_active() {
                        cfg.disabled_mods.push(folder.clone());
                    }
                    cfg.save();
                });
                mods_group.add(&row);
                added.borrow_mut().push((mods_group.clone(), row.upcast()));
            }
            if mods.is_empty() {
                let row = adw::ActionRow::builder().title("No Client Mods Found").build();
                row.add_css_class("dimmed");
                mods_group.add(&row);
                added.borrow_mut().push((mods_group.clone(), row.upcast()));
            }
        }
    };
    rebuild();
    let rebuild = Rc::new(rebuild);
    {
        let r = rebuild.clone();
        state.game_changed.borrow_mut().push(Box::new(move || r()));
        let r = rebuild.clone();
        refresh_btn.connect_clicked(move |_| r());
    }
    {
        let toasts = toasts.clone();
        open_btn.connect_clicked(move |_| {
            let dir = scan::user_dir(Kind::Mod);
            if let Err(e) = std::fs::create_dir_all(&dir) {
                toast(&toasts, &format!("Cannot create {}: {e}", dir.display()));
                return;
            }
            let uri = gio::File::for_path(&dir).uri();
            if let Err(e) = gio::AppInfo::launch_default_for_uri(&uri, gio::AppLaunchContext::NONE) {
                toast(&toasts, &format!("Cannot open the folder: {e}"));
            }
        });
    }
    page
}

// --------------------------------------------------------------- Settings

fn build_settings(state: &Shared) -> adw::PreferencesPage {
    let page = adw::PreferencesPage::new();

    let game = adw::PreferencesGroup::builder()
        .title("Game")
        .description("Leave the directory empty to use the checkout this launcher was built from, or set INSANOTIC_DIR.")
        .build();
    let path = adw::EntryRow::builder().title("Game Directory").show_apply_button(true).build();
    let choose = gtk::Button::builder()
        .icon_name("folder-open-symbolic")
        .valign(gtk::Align::Center)
        .tooltip_text("Choose Folder")
        .build();
    choose.add_css_class("flat");
    choose.update_property(&[gtk::accessible::Property::Label("Choose game directory")]);
    path.add_suffix(&choose);
    let using = adw::ActionRow::builder().title("In Use").subtitle_selectable(true).build();
    using.add_css_class("property");
    game.add(&path);
    game.add(&using);
    page.add(&game);

    path.set_text(&state.cfg.borrow().game_path);
    {
        let state2 = state.clone();
        let using = using.clone();
        let upd = move || using.set_subtitle(&glib::markup_escape_text(&state2.cfg.borrow().game_dir().to_string_lossy()));
        upd();
        state.game_changed.borrow_mut().push(Box::new(upd));
    }
    let apply_path = {
        let state = state.clone();
        move |text: &str| {
            state.cfg.borrow_mut().game_path = text.trim().to_string();
            state.cfg.borrow().save();
            // run the callbacks after releasing the borrow on cfg
            for f in state.game_changed.borrow().iter() {
                f();
            }
        }
    };
    let apply_path = Rc::new(apply_path);
    {
        let f = apply_path.clone();
        path.connect_apply(move |r| f(&r.text()));
    }
    {
        let f = apply_path.clone();
        let path = path.clone();
        choose.connect_clicked(move |b| {
            let dialog = gtk::FileDialog::builder().title("Choose the Insanotic Directory").build();
            let window = b.root().and_downcast::<gtk::Window>();
            let (f, path) = (f.clone(), path.clone());
            dialog.select_folder(window.as_ref(), gio::Cancellable::NONE, move |res| {
                if let Ok(file) = res {
                    if let Some(p) = file.path() {
                        let s = p.to_string_lossy().into_owned();
                        path.set_text(&s);
                        f(&s);
                    }
                }
            });
        });
    }

    let toggles = adw::PreferencesGroup::builder()
        .title("Quick Toggles")
        .description("Passed to the game every time it starts.")
        .build();
    let aim = combo("Aim Assist", &["Off", "Touchscreen only", "Any input"]);
    aim.set_subtitle("aim_assist_mode");
    let touch = adw::SwitchRow::builder()
        .title("Always Show Touch Controls")
        .subtitle("touch_controls_force, useful for testing on a desktop")
        .build();
    toggles.add(&aim);
    toggles.add(&touch);
    page.add(&toggles);
    aim.set_selected(state.cfg.borrow().aim_assist_mode.min(2));
    touch.set_active(state.cfg.borrow().touch_controls_force);
    {
        let s = state.clone();
        aim.connect_selected_notify(move |r| {
            s.cfg.borrow_mut().aim_assist_mode = r.selected();
            s.cfg.borrow().save();
        });
        let s = state.clone();
        touch.connect_active_notify(move |r| {
            s.cfg.borrow_mut().touch_controls_force = r.is_active();
            s.cfg.borrow().save();
        });
    }
    page
}
