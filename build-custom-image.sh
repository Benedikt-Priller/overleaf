#!/bin/bash
# Build script for creating custom Overleaf images with additional LaTeX packages
# Usage: ./build-custom-image.sh [PACKAGES_FILE] [IMAGE_TAG] [REGISTRY]

set -e

# Configuration
PACKAGES_FILE="${1:-.custom-packages}"
IMAGE_TAG="${2:-sharelatex-custom:latest}"
REGISTRY="${3:-.}"
DOCKERFILE_BASE="server-ce/Dockerfile-base"
DOCKERFILE="server-ce/Dockerfile"
TEXLIVE_MIRROR="${TEXLIVE_MIRROR:-https://mirror.ox.ac.uk/sites/ctan.org/systems/texlive/tlnet}"

# Color output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m' # No Color

echo -e "${GREEN}=== Overleaf Custom Image Builder ===${NC}"

# Check if packages file exists
if [ ! -f "$PACKAGES_FILE" ]; then
    echo -e "${YELLOW}No packages file found at '$PACKAGES_FILE'${NC}"
    echo "Usage: $0 [PACKAGES_FILE] [IMAGE_TAG] [REGISTRY]"
    echo ""
    echo "Example .custom-packages file:"
    echo "# LaTeX packages to pre-install"
    echo "package1"
    echo "package2"
    echo "package3"
    echo ""
    echo "Create this file and specify additional packages, one per line."
    PACKAGES=""
else
    echo -e "${GREEN}Reading packages from $PACKAGES_FILE${NC}"
    # Read packages, skip comments and empty lines
    PACKAGES=$(grep -v '^\s*#' "$PACKAGES_FILE" | grep -v '^\s*$' | tr '\n' ' ')
    echo "Packages to install: $PACKAGES"
fi

# Create a temporary Dockerfile with custom packages
echo -e "${GREEN}Creating temporary Dockerfile...${NC}"

TEMP_DOCKERFILE=$(mktemp)
cat "$DOCKERFILE_BASE" > "$TEMP_DOCKERFILE"

if [ -n "$PACKAGES" ]; then
    cat >> "$TEMP_DOCKERFILE" << 'EOF'

# Install additional custom packages specified by user
# -------------------------------------------------
RUN tlmgr install --repository ${TEXLIVE_MIRROR} \
EOF
    
    for pkg in $PACKAGES; do
        echo "      $pkg \\" >> "$TEMP_DOCKERFILE"
    done
    
    # Remove trailing backslash from last entry
    sed -i '$ s/ \\$//' "$TEMP_DOCKERFILE"
fi

# Build base image
echo -e "${GREEN}Building base image as ${IMAGE_TAG}-base...${NC}"
docker build -f "$TEMP_DOCKERFILE" \
    --build-arg TEXLIVE_MIRROR="$TEXLIVE_MIRROR" \
    -t "${REGISTRY}/${IMAGE_TAG}-base" \
    .

rm "$TEMP_DOCKERFILE"

# Build final image
echo -e "${GREEN}Building final image as ${REGISTRY}/${IMAGE_TAG}...${NC}"
docker build \
    --build-arg OVERLEAF_BASE_TAG="${REGISTRY}/${IMAGE_TAG}-base:latest" \
    -f "$DOCKERFILE" \
    -t "${REGISTRY}/${IMAGE_TAG}" \
    .

echo -e "${GREEN}=== Build Complete ===${NC}"
echo "Image: ${REGISTRY}/${IMAGE_TAG}"
echo ""
echo "You can now push to registry:"
echo "  docker push ${REGISTRY}/${IMAGE_TAG}-base"
echo "  docker push ${REGISTRY}/${IMAGE_TAG}"
echo ""
echo "Or use locally for testing:"
echo "  docker run -it ${REGISTRY}/${IMAGE_TAG} /bin/bash"
