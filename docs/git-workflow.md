# Git / GitHub 整合流程（feature branch + PR）

> 適用對象：第 13 組所有成員。
> 目標：在 `aoc-final-group13` repo 上以**乾淨、不互相覆蓋**的方式協作。

---

## 0. 一次性設定（每個人裝完 git 後做一次）

```bash
git config --global user.name  "<你的姓名>"
git config --global user.email "<連結到 GitHub 帳號的 email>"
git config --global init.defaultBranch main
git config --global pull.rebase true        # 預設用 rebase 同步 main，避免一堆 merge bubble
git config --global core.autocrlf input     # macOS / Linux 推薦
```

驗證：

```bash
git config --global --get user.email   # 必須跟你 GitHub 帳號 email 一致
gh auth status                          # 確認 GitHub CLI 已登入
```

> ⚠️ **Email 不一致的後果**：commits 會 push 上去，但 GitHub 顯示為「未連結帳號」，contribution graph 不會記錄、組員無法從頭像認出你。

---

## 1. 命名公約

### Branch 命名
| Prefix | 用途 | 範例 |
|--------|------|------|
| `feat/` | 新功能 | `feat/quill-pe-array-rtl` |
| `fix/` | bug 修復 | `fix/po-mfiu-overflow` |
| `docs/` | 純文件變更 | `docs/jia-update-readme` |
| `refactor/` | 重構（行為不變） | `refactor/quill-tb-cleanup` |
| `chore/` | 雜項（CI、依賴） | `chore/po-add-pre-commit` |

格式：`<type>/<名字縮寫>-<主題>`，全小寫、用 hyphen 不用底線。

### Commit message — Conventional Commits
```
<type>: <subject>

[optional body]
```
- `<type>` 同上 prefix
- `<subject>` 一句話、現在式、不超過 72 字元
- 多行細節放 body，與 subject 隔一行空白

範例：
```
feat: add MFIU intersection unit RTL skeleton

- 8-bit fiber pointer comparator
- Output queue depth = 4
- Untested; testbench in next PR
```

---

## 2. 每日工作循環（5 個指令）

```bash
# 1. 拿最新 main
git switch main
git pull --rebase

# 2. 切新 branch
git switch -c feat/<你的名字>-<主題>

# 3. ... 改 code、寫 commit ...
git add <檔案>            # 不要用 git add . 除非你看過 git status
git commit -m "feat: ..."

# 4. push 到 GitHub（首次需 -u 設定追蹤）
git push -u origin feat/<你的名字>-<主題>

# 5. 開 PR
gh pr create --fill --web
```

在 GitHub 網頁上：**Files changed** → 自我 review → Reviewers 指定組員 → 等 approve → Squash and merge。

---

## 3. 整合衝突 (merge conflict) 處理

兩種常見情境：

### A) 你 push 前 main 已經更新

```bash
# 在你的 feature branch 上
git fetch origin
git rebase origin/main           # 把你的 commits rebase 到最新 main 上
# 如果有衝突：
git status                       # 看哪些檔案衝突 (<<<<<<< HEAD ... >>>>>>>)
# 編輯衝突檔，移除 conflict markers
git add <解完的檔>
git rebase --continue
# 一切順利後：
git push --force-with-lease       # ⚠️ 注意：rebase 後必須 force push，但用 --force-with-lease 較安全
```

> ❓ 為什麼用 `--force-with-lease` 而不是 `--force`？
> `--force-with-lease` 會先檢查遠端 branch 是不是還是你上次看到的那個版本——如果有人在你不知情的情況下推了東西上去，它會擋下來，避免你蓋掉他的工作。**永遠用 `--force-with-lease`，永遠不要用 `--force`**。

### B) 真的解不開、想放棄重來

```bash
git rebase --abort               # 取消 rebase，回到 rebase 前的狀態
```

---

## 4. PR 模板（建議內容）

開 PR 時，body 區塊建議包含：

```markdown
## Summary
<這個 PR 在做什麼，1–3 句>

## Changes
- <具體改動 1>
- <具體改動 2>

## How to test
- [ ] <測試方法 / 跑哪個 script>
- [ ] <預期看到什麼結果>

## Related
- Closes #<issue 編號>
- Refs proposal-review.md `## PE array sizing` 章節
```

---

## 5. Code Review 禮節

### Reviewer 該做的
- 用 GitHub「Files changed」逐行看
- 不確定的地方留 **comment** (問問題)
- 想要對方改的具體建議用 **Suggestion** (✅ 一鍵採納)
- 沒問題就 **Approve**；有疑慮但不擋 merge → **Comment**；有 bug 必須改 → **Request changes**

### PR 作者該做的
- **不要自己 merge 自己的 PR**（除非真的時間緊急、組員都同意）
- 至少 1 個 approve 才 merge
- merge 完把 feature branch 刪掉（GitHub 會問你要不要 Delete branch）

### 兩個禁忌
- ❌ 不要直接 push 到 `main`（除非 emergency hotfix）
- ❌ 不要 `git push --force` 到 `main`（會洗掉組員的 commits）

---

## 6. Docker 內 vs Host git

| | Host (macOS) | Docker container |
|---|---|---|
| 推薦做 git? | ✅ 預設用這個 | ⚠️ 只在必要時 |
| `git config` 來源 | `~/.gitconfig` (host) | 容器內 home（每次 run 可能不一樣） |
| commit 作者 email | 你 host 設好的 | 容器內可能空白或預設值 |

**結論**：所有 `git`、`gh`、`commit`、`push` 都在 host 跑。容器只用來跑 RTL/Python 工具。

如果**真的**要在容器內做 git（例如 commit 容器內生成的檔），先在容器裡跑：
```bash
git config --global user.name  "<你的名字>"
git config --global user.email "<email>"
```

---

## 7. 救援 cheat sheet

| 情境 | 指令 |
|------|------|
| 我 commit 錯了想撤回最後一個（保留改動） | `git reset --soft HEAD^` |
| 我 commit 錯了想徹底丟掉（⚠️ 改動會消失） | `git reset --hard HEAD^` |
| 我 add 了不該 add 的檔案（還沒 commit） | `git restore --staged <檔>` |
| 我改了某檔但想還原（還沒 add） | `git restore <檔>` |
| 我手滑刪了一個 branch / 重要 commit | `git reflog` 找到 commit hash → `git checkout -b rescue <hash>` |
| 我想暫存改動切去別的 branch | `git stash` ，回來 `git stash pop` |
| 看誰改了某行 | `git blame <檔>` |

> 💡 **黃金法則**：只要還沒 `git push`，你做的事情幾乎都救得回來——`git reflog` 是你最好的朋友。push 之後就要小心，特別是 force push。

---

## 8. 常見問題 FAQ

**Q1：我 push 上去的 commits 在 GitHub 上頭像是灰色 / 沒連結到我帳號？**
A：你的 `git config user.email` 跟 GitHub 帳號 email 不一致。改完只影響未來 commits（過去的不會自動修，也不該強行回溯）。

**Q2：我 `git pull` 出現 "fatal: refusing to merge unrelated histories"？**
A：你 init 過後又 clone / fetch 了不同來源。一般情況下不應該發生；如果真的需要：`git pull --allow-unrelated-histories`（先確認你了解後果）。

**Q3：PR 開了之後我又改了 code，要怎麼更新 PR？**
A：在同一 branch 上多 commit、push，PR 會自動更新。不需要關掉重開。

**Q4：我可以在容器內 push 嗎？**
A：技術上可以（容器內有 git），但 commit 作者會跑掉、SSH key 也不在容器裡。**強烈建議只在 host 操作 git**。
