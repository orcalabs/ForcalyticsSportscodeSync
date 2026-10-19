if [ ! -e "ForcalyticsSportscodeSync.app" ]; then
    echo "Missing ForcalyticsSportscodeSync.app"
    exit
fi

zip -r ForcalyticsSportscodeSync.zip ForcalyticsSportscodeSync.app

# Get the highest existing vN tag and increment it
git fetch --tags

latest=$(git tag -l 'v[0-9]*' |
  grep -E '^v[0-9]+$' |
  sed 's/^v//' |
  sort -n |
  tail -1)

next=$(( ${latest:-0} + 1 ))
tag="v$next"

# Publish the release
gh release create "$tag" ForcalyticsSportscodeSync.zip \
  --title "$tag" \
  --notes "" \
  --latest

echo "Published release $tag"
