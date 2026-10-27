#!/bin/bash
# Prints the UI tests a change can affect, one per line ("Class" or "Class/testMethod"), or "all". Prints nothing when
# the change can't affect the app (documentation, package tests).
#
# Usage: scripts/ui-tests-for-changes.sh [base]      (base defaults to origin/main)
# Compares the working tree, new files included, with the commit where the branch left `base`.
#
# Pull requests run only these UI tests on CI. Pushes to main and runs started by hand run every UI test, so main is
# always fully tested before a release. Paths not listed below select every test, so new folders stay covered until
# they're mapped here; a test named here that no longer exists does too.
set -euo pipefail
cd "$(dirname "$0")/.."

base=${1:-origin/main}
fork=$(git merge-base "$base" HEAD)
files=$( { git diff --name-only "$fork"; git ls-files --others --exclude-standard; } | sort -u)

selected=""
all=false
pick() { for test in "$@"; do selected+="$test"$'\n'; done; }

launch=NavigationUITests/testLaunchShowsDashboardAndSampleProjects
while IFS= read -r file; do
    [ -z "$file" ] && continue
    case "$file" in
        # Nothing the app runs.
        docs/* | *.md | Design/* | spikes/* | .gitignore | .swift-format | Packages/RelvoraKit/Tests/*) ;;
        scripts/make-app-icon.swift | scripts/release/* | .github/workflows/release.yml) ;;
        # How UI tests run: one quick test shows the job still works.
        .github/workflows/ci.yml | scripts/ui-tests-for-changes.sh) pick "$launch" ;;
        # A UI test file: that test.
        UITests/*UITests.swift) pick "$(basename "$file" .swift)" ;;

        # Features.
        App/Features/Board/*)
            pick BoardUITests AccessibilityUITests/testBoardPassesAccessibilityAudit \
                AccessibilityUITests/testBacklogPassesAccessibilityAudit ;;
        App/Features/Projects/*) pick BoardUITests NavigationUITests ;;
        App/Features/Dashboard/*) pick "$launch" AccessibilityUITests/testDashboardPassesAccessibilityAudit ;;
        App/Features/History/*) pick ReleaseWorkflowUITests/testDraftPublicationAndHistory ;;
        App/Features/Releases/*)
            pick ReleaseWorkflowUITests PullRequestUITests ErrorStateUITests/testOfflineReleaseCheckExplainsTheProblem \
                AccessibilityUITests/testReleasePlanPassesAccessibilityAudit ;;
        App/Features/GitHub/*)
            pick PullRequestUITests ReleaseWorkflowUITests ErrorStateUITests/testOfflineRefreshKeepsCachedRepositoryData ;;
        App/Features/Notifications/*) pick NotificationUITests ;;
        App/Features/Claude/*) pick ClaudeUITests NotificationUITests ;;
        App/Features/Updates/*) pick UpdateUITests NotificationUITests ;;
        App/Features/Settings/*) pick SettingsUITests ;;
        App/Features/Backup/*) pick "$launch" ;;
        App/Navigation/*) pick NavigationUITests AccessibilityUITests ;;
        App/DesignSystem/* | App/Assets.xcassets/*) pick NavigationUITests AccessibilityUITests ;;
        App/AppModel.swift) pick "$launch" NotificationUITests ;;
        App/Debug/DemoGitHub.swift)
            pick ReleaseWorkflowUITests PullRequestUITests ErrorStateUITests UpdateUITests NotificationUITests ;;

        # Packages.
        Packages/RelvoraKit/Sources/GitHubIntegration/*)
            pick ReleaseWorkflowUITests PullRequestUITests ErrorStateUITests UpdateUITests ;;
        Packages/RelvoraKit/Sources/RelvoraMCP/*) pick ClaudeUITests NotificationUITests ;;
        Packages/RelvoraKit/Sources/RelvoraUpdates/* | Updater/*) pick UpdateUITests ;;
        Packages/RelvoraKit/Sources/RelvoraCore/Services/AppNotifications.swift) pick NotificationUITests ;;
        Packages/RelvoraKit/Sources/RelvoraCore/Services/PullRequests.swift) pick PullRequestUITests NotificationUITests ;;
        Packages/RelvoraKit/Sources/RelvoraCore/Services/AppUpdate.swift) pick UpdateUITests ;;
        Packages/RelvoraKit/Sources/RelvoraCore/Services/BoardPlanner.swift | \
            Packages/RelvoraKit/Sources/RelvoraCore/Services/BoardService.swift | \
            Packages/RelvoraKit/Sources/RelvoraCore/Services/Filtering.swift)
            pick BoardUITests ;;
        Packages/RelvoraKit/Sources/RelvoraCore/Services/Changelog.swift | \
            Packages/RelvoraKit/Sources/RelvoraCore/Services/Release*.swift | \
            Packages/RelvoraKit/Sources/RelvoraCore/Services/VersionSuggestion.swift)
            pick ReleaseWorkflowUITests ;;

        # Everything else: the app's setup, menus, sample data, persistence, models, the project and its settings.
        *) all=true ;;
    esac
done <<< "$files"

if $all; then
    echo all
    exit 0
fi

# A whole class makes its single tests redundant.
tests=$(printf '%s' "$selected" | sed '/^$/d' | sort -u | awk -F/ '
    { line[NR] = $0; class[NR] = $1; parts[NR] = NF; if (NF == 1) whole[$1] = 1 }
    END { for (i = 1; i <= NR; i++) if (parts[i] == 1 || !(class[i] in whole)) print line[i] }')

# Every test named must exist; otherwise run everything rather than silently nothing.
while IFS= read -r test; do
    [ -z "$test" ] && continue
    source="UITests/${test%%/*}.swift"
    if [ ! -f "$source" ] || { [[ "$test" == */* ]] && ! grep -q "func ${test#*/}(" "$source"; }; then
        echo "ui-tests-for-changes: $test isn't a UI test; running all of them" >&2
        echo all
        exit 0
    fi
done <<< "$tests"

printf '%s\n' "$tests" | sed '/^$/d'
