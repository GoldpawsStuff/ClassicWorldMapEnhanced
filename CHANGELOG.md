# ClassicWorldMapEnhanced Change Log
All notable changes to this project will be documented in this file. All notable changes to this project will be documented in this file. Be aware that the [Unreleased] features are not yet available in the official tagged builds.

The format is based on [Keep a Changelog](http://keepachangelog.com/)
and this project adheres to [Semantic Versioning](http://semver.org/).

## [2.3.36-Release] 2023-10-19
### Fixed
- Fixed an issue that prevent external libraries from being embedded by the packager, thus breaking the entire addon.

## [2.3.35-Release] 2023-10-18
### Fixed
- Fixed an issue where the map would refuse to fade if shown while the player was already moving.

## [2.3.34-Release] 2023-10-17
- Rewrote addon to use external libraries in preparation for future updates.

## [1.3.33-Release] 2023-10-13
### Fixed
- Fixed an issue in Wrath 3.4.3 where a centered, minimized map would appear automatically upon the first login.

## [1.3.32-Release] 2023-10-13
### Added
- Added compatibility with WoW Client Patch 3.4.3 and the new map with its built-in quest helper functionality.

## [1.2.31-Release] 2023-10-11
### Removed
- Removed Wrath compatibility as Blizzard replaced their entire WorldMap in WoW Client Patch 3.4.3, and it is no longer compatible with this addon.

## [1.2.30-Release] 2023-08-24
- Updated for Classic client patch 1.14.4.

## [1.2.29-Release] 2023-06-21
- Bumped to Wrath Classic Client Patch 3.4.2.

## [1.2.28-Release] 2023-01-18
- Updated for WoW 3.4.1.

## [1.2.27-Release] 2022-09-07
### Added
- Added levels for Wrath zones.
- Added fog of war removal for Wrath zones.

### Changed
- Switched to single addon with multiple toc-file format.

## [1.2.25-Release] 2022-07-09
- Bump for Classic Era client patch 1.14.3.

## [1.2.24-Release] 2022-04-07
- Bump for BCC client patch 2.5.4.

## [1.2.23-Release] 2022-02-16
- ToC bumps and license update.

## [1.2.22-Release] 2021-11-17
- Bump Classic Era toc to client patch 1.14.1.

## [1.2.21-Release] 2021-10-18
- Bump Classic Era toc to client patch 1.14.

## [1.2.20-Release] 2021-09-19
### Changed
- Our "Fog of War" button should now get out of the way when Questie's "Hide Questie" button decides to move into the upper right corner.

## [1.2.19-Release] 2021-09-01
- Bump TOC for BCC 2.5.2.

## [1.2.18-Release] 2021-05-20
### Added
- Added an option in the top left corner to toggle the movement fading.

### Fixed
- Fixed a Blizzard bug that would cause a bug when hovering above the zone map menu when no keybind for the zone map has been set.

## [1.2.17-Release] 2021-05-17
- Extra push needed because the bigwigs packager changed its API from using "bc" to calling it "bcc".

## [1.2.16-Release] 2021-05-17
### Added
- Added zone data for Burning Crusade Classic.

### Changed
- Moved zone data to a separate file to make it a little easier to support multiple WoW client versions.

## [1.1.15-Release] 2021-05-05
### Changed
- Reduced the opacity when moving to 50%, down from its previous 65%. Let's see if this makes it a bit easier to navigate while moving!

## [1.1.14-Release] 2021-04-22
- Bump toc version.

## [1.1.13-Release] 2021-04-20
- Bump toc version.
- Add metatags for packager.

## [1.1.12-Release] 2021-04-20
- Using BigWigs packager from now on.
- Preparing for Wago.

## [1.1.11-Release] 2021-03-25
### Fixed
- Fixed a minor bug in the localization system.

## [1.1.10-Release] 2020-08-02
### Changed
- Updated for WoW Classic Client Patch 1.13.5.

## [1.1.9-Release] 2020-03-11
### Changed
- Updated for WoW Classic Client Patch 1.13.4.

## [1.1.8-Release] 2019-12-11
### Changed
- Updated for WoW Classic Client Patch 1.13.3.

## [1.1.7-Release] 2019-10-08
### Changed
- Re-arranged the code a bit, improved the function names to be more descriptive of what they do, and added better commenting for anybody looking to disect the addon and learn from it.
- Updated ToC file links to reflect my current patreon and paypal, and removed redundant entries.

## [1.1.6-Release] 2019-09-24
### Added
- Added the optional feature to disable Fog of War, thus revealing unexplored areas of the map. This feature is enabled by default.
- Enabled the use of the mouse wheel to zoom in and out.

## [1.0.5-Release] 2019-09-18
### Changed
- This addon won't interfere with Leatrix Maps anymore.

## [1.0.4-Release] 2019-09-12
### Changed
- Updated zone levels to be consistent with [gamepedia.com/Zones_by_level_(Classic)](https://wow.gamepedia.com/Zones_by_level_(Classic))

## [1.0.3-Release] 2019-09-08
### Added
- Added reaction colored zone faction names for zones owned by either of the factions. Red means it's a hostile zone, green means it's a friendly zone.

## [1.0.2-Release] 2019-09-05
### Fixed
- CurseForge should now look in the correct repository, and not give you AzeriteUI for WoW Classic instead. SORRY!!!

## [1.0.1-Release] 2019-09-04
- Release.
