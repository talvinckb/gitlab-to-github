<div align="center">
  <h1>🚀 GitLab to GitHub Migrator</h1>
  <p><strong>A simple, robust, and interactive bash script to migrate your GitLab repositories to GitHub.</strong></p>
  
  [![Bash](https://img.shields.io/badge/Language-Bash-4EAA25?style=flat-square&logo=gnu-bash&logoColor=white)]()
  [![License](https://img.shields.io/badge/License-MIT-blue.svg?style=flat-square)]()
</div>

<br />

> ⚠️ **Note:** This tool performs a clean Git migration (commits, branches, tags) using a mirror clone. It does **not** migrate issues, merge requests, or CI pipelines. The source GitLab repository is never modified.

## ✨ Features

- **Interactive UI**: Clean and user-friendly terminal interface.
- **Safe & Non-Destructive**: The source repository on GitLab is only read, never modified.
- **Private by Default**: Automatically creates a private repository on GitHub if it doesn't exist.
- **Isolated Execution**: Runs in an alternate screen buffer (like `less` or `vim`) keeping your terminal history perfectly clean.
- **Complete Git History**: Uses `--mirror` clone/push to ensure absolutely all branches, tags, and commits are migrated.

## 📋 Prerequisites

To run this script, you must have the following installed on your system:

- `git`
- `curl`

You will also need:

- Your GitLab project URL (HTTPS or SSH)
- A **GitHub Personal Access Token (PAT)** with `repo` scopes (used to check/create the target repository).

## 🚀 Installation

You can install the migrator easily by downloading the latest version from the releases page, or via a simple `curl` command.

### Option 1: Quick Install (Recommended)

Run the following command to download the script, make it executable, and move it to your system's `PATH`:

```bash
curl -sSL https://raw.githubusercontent.com/talvinckb/gitlab-to-github/main/gitlab-to-github.sh -o gitlab-to-github
chmod +x gitlab-to-github
sudo mv gitlab-to-github /usr/local/bin/
```

### Option 2: Install from GitHub Releases

1. Go to the [Releases page](https://github.com/talvinckb/gitlab-to-github/releases) of this repository.
2. Download the `gitlab-to-github.sh` file from the latest release assets.
3. Make it executable and move it to your PATH:
   ```bash
   chmod +x gitlab-to-github.sh
   sudo mv gitlab-to-github.sh /usr/local/bin/gitlab-to-github
   ```

## 💻 Usage

Once installed, simply run the tool from anywhere in your terminal:

```bash
gitlab-to-github
```

Follow the interactive prompts:

1. Provide your **GitLab source project URL** (e.g., `https://gitlab.com/username/project.git` or `git@gitlab.com:username/project.git`).
2. Provide your **GitHub target repo URL** (e.g., `https://github.com/username/project.git`).
3. Provide your **GitHub access token**.
4. Confirm the summary and let the script do the magic!

## 🤝 Contributing

Contributions, issues, and feature requests are welcome! Feel free to check the [issues page](https://github.com/talvinckb/gitlab-to-github/issues).

## 📝 License

This project is licensed under the MIT License.
