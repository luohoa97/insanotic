// SPDX-License-Identifier: GPL-3.0-or-later
//! Insanotic launcher: play, host a local server and manage Lua mods.

mod config;
mod scan;
mod window;

use adw::prelude::*;
use gtk::{gio, glib};

pub const APP_ID: &str = "io.github.luohoa97.Insanotic";

fn main() -> glib::ExitCode {
    let app = adw::Application::builder().application_id(APP_ID).build();
    app.connect_startup(|_| {
        // lets a not-yet-installed launcher find its icon (make launcher-install
        // puts it into the user's icon theme)
        if let Some(display) = gtk::gdk::Display::default() {
            let dir = std::path::Path::new(env!("CARGO_MANIFEST_DIR")).join("data/icons");
            gtk::IconTheme::for_display(&display).add_search_path(dir);
        }
        gtk::Window::set_default_icon_name(APP_ID);
    });
    app.connect_activate(|app| {
        if let Some(win) = app.active_window() {
            win.present();
            return;
        }
        let win = window::build(app);
        win.present();
    });

    let about = gio::ActionEntry::builder("about")
        .activate(|app: &adw::Application, _, _| {
            let dialog = adw::AboutDialog::builder()
                .application_name("Insanotic")
                .application_icon(APP_ID)
                .developer_name("The Insanotic contributors")
                .version(env!("CARGO_PKG_VERSION"))
                .comments("Launcher for Insanotic, a Xonotic fork with Lua scripting.")
                .website("https://github.com/luohoa97/insanotic")
                .license_type(gtk::License::Gpl30)
                .build();
            dialog.present(app.active_window().as_ref());
        })
        .build();
    let quit = gio::ActionEntry::builder("quit")
        .activate(|app: &adw::Application, _, _| app.quit())
        .build();
    app.add_action_entries([about, quit]);
    app.set_accels_for_action("app.quit", &["<Control>q"]);
    app.run()
}
