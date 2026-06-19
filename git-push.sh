#!/bin/bash
# ============================================================
# 一键推送到 GitHub
# 使用前请先在 GitHub 创建空仓库:
#   https://github.com/new
#   仓库名建议: tcp-tune
#   不要勾选 README / .gitignore / license
# ============================================================

set -e

REPO_NAME="${1:-tcp-tune}"
GITHUB_USER="1731134683x"
REMOTE_URL="https://github.com/${GITHUB_USER}/${REPO_NAME}.git"

# 确保 git 用户已配置
if [[ -z "$(git config --global user.name 2>/dev/null)" ]]; then
    echo "Git user.name 未设置，请输入你的 GitHub 用户名:"
    read -r uname
    git config --global user.name "$uname"
fi
if [[ -z "$(git config --global user.email 2>/dev/null)" ]]; then
    echo "Git user.email 未设置，请输入你的邮箱:"
    read -r uemail
    git config --global user.email "$uemail"
fi

echo "==> 初始化 Git 仓库..."
git init
git branch -M main

echo "==> 添加所有文件..."
git add .

echo "==> 提交..."
git commit -m "$(cat <<'EOF'
feat: BBRv3 kernel installer + TCP tuning suite + AI prompt generator

- install-bbrv3.sh: auto-detect arch, fetch pre-compiled BBRv3 kernel from byJoey/Actions-bbr-v3
- tcp-tune.sh: VPS specs detection, dual-stack latency test, sysctl tuning
- tcp-full.sh: all-in-one (kernel install + tuning + custom template + AI prompt)
- README.md: full documentation

Co-Authored-By: Claude Opus 4.7 <noreply@anthropic.com>
EOF
)"

echo "==> 添加远程仓库..."
git remote add origin "$REMOTE_URL"

echo "==> 推送到 GitHub..."
git push -u origin main

echo ""
echo "Done! 仓库地址: https://github.com/${GITHUB_USER}/${REPO_NAME}"
