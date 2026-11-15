# Where builds go; sourced by build.sh and release.sh.
# When /Volumes/Code/.derived exists (the author's Mac), build output stays out of the source folder.
if [ -d /Volumes/Code/.derived ]; then
  objs=/Volumes/Code/.derived/accsoon-mac-app/swift
  apps=/Volumes/Code/.derived/accsoon-mac-app
else
  objs=.build
  apps=build
fi
