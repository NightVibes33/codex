use clap::Parser;
use std::path::PathBuf;

#[derive(Debug, Parser)]
pub struct AppCommand {
    /// Workspace path to open in the Desktop app.
    #[arg(value_name = "PATH", default_value = ".")]
    pub path: PathBuf,

    /// Override the app installer download URL (advanced).
    #[arg(long = "download-url")]
    pub download_url_override: Option<String>,
}

pub async fn run_app(cmd: AppCommand) -> anyhow::Result<()> {
    let AppCommand {
        path,
        download_url_override,
    } = cmd;
    let workspace = std::fs::canonicalize(&path).unwrap_or(path);

    #[cfg(all(target_os = "macos", target_arch = "x86_64"))]
    if download_url_override.is_none() && macos_needs_high_sierra_compat_app() {
        return run_high_sierra_app(workspace);
    }

    #[cfg(target_os = "macos")]
    {
        crate::desktop_app::run_app_open_or_install(workspace, download_url_override).await
    }
    #[cfg(target_os = "windows")]
    {
        crate::desktop_app::run_app_open_or_install(workspace, download_url_override).await
    }
}

#[cfg(all(target_os = "macos", target_arch = "x86_64"))]
fn macos_needs_high_sierra_compat_app() -> bool {
    let Ok(output) = std::process::Command::new("/usr/bin/sw_vers")
        .arg("-productVersion")
        .output()
    else {
        return false;
    };
    if !output.status.success() {
        return false;
    }

    let version = String::from_utf8_lossy(&output.stdout);
    let mut parts = version.trim().split('.');
    let Some(major) = parts.next().and_then(|part| part.parse::<u32>().ok()) else {
        return false;
    };
    let minor = parts
        .next()
        .and_then(|part| part.parse::<u32>().ok())
        .unwrap_or(0);

    matches!(major, 11 | 12) || (major == 10 && (13..=15).contains(&minor))
}

#[cfg(all(target_os = "macos", target_arch = "x86_64"))]
fn run_high_sierra_app(workspace: PathBuf) -> anyhow::Result<()> {
    const INSTALLER_URL: &str =
        "https://raw.githubusercontent.com/NightVibes33/codex/main/scripts/install-chatgpt-high-sierra.sh";

    let install_base = std::env::var_os("CHATGPT_HIGH_SIERRA_INSTALL_BASE")
        .map(PathBuf::from)
        .or_else(|| std::env::var_os("HOME").map(|home| PathBuf::from(home).join("Applications")))
        .ok_or_else(|| anyhow::anyhow!("HOME is not set"))?;
    let app_path = install_base.join("ChatGPT.app");

    if !app_path.is_dir() {
        println!("Installing the High Sierra-compatible real ChatGPT/Codex app...");
        let command =
            format!("curl -fsSL {INSTALLER_URL} | CHATGPT_HIGH_SIERRA_NO_LAUNCH=1 /bin/bash");
        let status = std::process::Command::new("/bin/bash")
            .arg("-c")
            .arg(command)
            .status()?;
        if !status.success() {
            anyhow::bail!("ChatGPT High Sierra compatibility installer failed with status {status}");
        }
    }

    let status = std::process::Command::new("/usr/bin/open")
        .arg("-a")
        .arg(&app_path)
        .arg(&workspace)
        .status()?;
    if !status.success() {
        anyhow::bail!(
            "failed to open {} with workspace {}: {status}",
            app_path.display(),
            workspace.display()
        );
    }
    Ok(())
}
