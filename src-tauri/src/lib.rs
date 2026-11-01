use tauri::Manager;

#[cfg_attr(mobile, tauri::mobile_entry_point)]
pub fn run() {
    let mut builder = tauri::Builder::default();

    #[cfg(windows)]
    {
        builder = builder.plugin(tauri_plugin_single_instance::init(|app, _args, _cwd| {
            if let Some(window) = app.get_webview_window("main") {
                let _ = window.set_focus();
            }
        }));
    }

    builder = builder.plugin(tauri_plugin_deep_link::init());

    builder
        .setup(|app| {
            #[cfg(windows)]
            {
                use tauri_plugin_deep_link::DeepLinkExt;

                // Allow the custom scheme to work while running the desktop app
                // directly during local development as well as after installation.
                #[cfg(debug_assertions)]
                app.deep_link().register_all()?;
            }

            Ok(())
        })
        .run(tauri::generate_context!())
        .expect("error while running Material Management System");
}
