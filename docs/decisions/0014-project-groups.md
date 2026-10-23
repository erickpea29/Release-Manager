# 0014 — Project groups

- **Status:** Accepted (0.1.1; the owner chose this model)
- **Date:** 2026-10-23

## Context

The owner has several projects and repositories per company, such as a website, an API, and an iOS app, and asked to separate and group them. A project can already connect several repositories, but it has one Board and one version in progress at a time. Two models were considered:
- **Groups of projects:** a group, such as a company, holds projects. Each project keeps its own Backlog, Board, versions, and repositories, and releases on its own.
- **One project with several release tracks:** each repository releases its own versions at the same time. This means several versions in progress per project and a Board and Backlog filtered by repository. It would rework ADR 0012 and the release workflow.

The owner chose groups. "Group" is the word in menus, because people group by company, client, or product.

## Decisions

1. **One level of groups.**
   - A `ProjectGroup` has a name, unique ignoring case, and a position.
   - A project is in at most one group (`Project.groupID`), or in none.
   - Groups only organize the sidebar, the Dashboard, quick actions, and the Release History filter. They don't affect boards, versions, or releases.
2. **Storage: schema V4 and backup format 5.**
   - `ProjectGroupEntity` and an optional `ProjectEntity.group` relationship, added by a lightweight migration from V3.
   - A V3 store from 0.1.0 (`RelvoraV3.store`, frozen before this change) migrates with every record intact and every project outside a group.
   - Deleting a group keeps its projects; they leave the group.
   - The repository refuses a project in a group that doesn't exist, rather than silently ungrouping it.
   - Backups carry the groups and each project's group. Format 4 files restore with no groups. 0.1.0 refuses format 5 files instead of dropping the groups.
3. **Sidebar.**
   - One collapsible section per group, in the groups' order, then **Other Projects** (just **Projects** while there are no groups). Folded groups are remembered per window.
   - An empty group shows "No projects" and takes dropped projects.
   - Projects change groups by dragging them between sections, from **Move to Group** in their context menu, or in the project editor.
   - A group's heading has a menu: New Project in the group, Rename, Move Up or Down, and Delete.
   - Searching matches a group's name too, and opens every group.
   - The collapsed sidebar keeps the same order, with a line between groups and the group's name in each project's tooltip.
4. **Elsewhere.**
   - The Dashboard's projects are grouped under the groups' names.
   - Quick actions name a project's group, so typing a company's name lists its projects.
   - Release History filters by a whole group or by a single project.
   - **File › New Group…** (⌃⌘N; ⌥⌘N was tried, but ⌥N is a dead key and never reached the menu) and a button at the bottom of the sidebar.

## Consequences

- With no groups, Relvora looks as it did in 0.1.0.
- A product released from several repositories is several projects in one group, each with its own versions. If shared versions across repositories become necessary later, that is the second model, as a separate decision.
- Groups are a store schema change. V4 is frozen once 0.1.1 is released, and later changes add V5.
