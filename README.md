<div align="center">
  <h1>🚀 GitLab to GitHub Migrator</h1>
  <p><strong>A simple, robust, and interactive script to migrate GitLab repositories to GitHub (code, wikis, issues, merge requests, labels & milestones).</strong></p>
  
  [![Bash](https://img.shields.io/badge/Language-Bash-4EAA25?style=flat-square&logo=gnu-bash&logoColor=white)]()
  [![Python](https://img.shields.io/badge/Language-Python-3776AB?style=flat-square&logo=python&logoColor=white)]()
  [![License](https://img.shields.io/badge/License-MIT-blue.svg?style=flat-square)]()
</div>

<br />

> 🔒 **Safe & Non-Destructive**: The source GitLab repository is only read, never modified.

## ✨ Features

- **Full Code Migration**: Uses `--mirror` clone/push to preserve all branches, tags, and commits.
- **Wikis**: Automatically detects and migrates GitLab wikis.
- **Issues & Merge Requests**: Migrates all issues, comments, labels, and milestones.
- **Smart MR Fallbacks**: Handles merged MRs whose source branches were deleted by generating a consolidated `MIGRATION_REPORT.md` or dedicated GitHub issues.
- **Interactive Prompts**: Prompts for access tokens securely and asks confirmation before each optional step.

## 📋 Prerequisites

To run this script, ensure you have installed:

- `git`
- `curl`
- `python3`

Tokens needed:
- **GitHub Access Token** (scopes: `repo`, `workflow`)
- **GitLab Personal Access Token** (scope: `read_api` — *only required if migrating issues/MRs*)

## 🚀 One-Line Execution (No Installation Required)

Run the migrator directly in your terminal without downloading or cloning manually:

```bash
bash <(curl -sSL https://raw.githubusercontent.com/talvinckb/gitlab-to-github/main/migrate.sh)
```

## 📦 System-Wide Installation (Optional)

If you prefer installing the CLI globally on your system:

```bash
sudo curl -sSL https://raw.githubusercontent.com/talvinckb/gitlab-to-github/main/migrate.sh -o /usr/local/bin/gitlab-to-github && sudo chmod +x /usr/local/bin/gitlab-to-github
```

Then run it anytime with:

```bash
gitlab-to-github
```

## 🤝 Contributing

Contributions, issues, and feature requests are welcome! Feel free to check the [issues page](https://github.com/talvinckb/gitlab-to-github/issues).

## 📝 License

This project is licensed under the MIT License.

