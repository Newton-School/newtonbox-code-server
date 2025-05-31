#!/usr/bin/bash

export DEBIAN_FRONTEND=noninteractive
export VERSION=${CODEBUILD_WEBHOOK_HEAD_REF#refs/heads/}@$CODEBUILD_SOURCE_VERSION
export ARTIFACT_NAME=code-server-$VERSION-linux-$ARCH
export ARTIFACT_FILE=$ARTIFACT_NAME.tar.gz

install_phase() {

    echo "Enabling swap ===>"
    fallocate -l 8G /swapfile
    chmod 600 /swapfile
    mkswap /swapfile
    swapon /swapfile
    echo '/swapfile none swap sw 0 0' | sudo tee -a /etc/fstab
    free -h
    swapon --show
    echo "<================="

    echo "Checking AWS credentials ===>"
    aws sts get-caller-identity
    aws s3 ls s3://$ARTIFACT_BUCKET
    echo "<============================"

    echo "Installing base dependencies ===>"
    apt-get update
    apt-get install -y curl git libxkbfile-dev time ca-certificates
    echo 'deb [trusted=yes] https://repo.goreleaser.com/apt/ /' |  tee /etc/apt/sources.list.d/goreleaser.list
    apt-get update
    apt-get install -y nfpm
    echo "<================================"

    echo "Installing NVM and Node.js ===>"
    curl -o- https://raw.githubusercontent.com/nvm-sh/nvm/$NVM_VERSION/install.sh | bash
    export NVM_DIR="$HOME/.nvm"
    . "$NVM_DIR/nvm.sh"
    nvm install $NODE_VERSION
    nvm use $NODE_VERSION
    node -v
    npm -v
    echo "<=============================="

    echo "Installing code-server dependencies ===>"
    npm ci
    echo "<======================================="

}

build_phase() {

    echo Build started at `date`

    export NVM_DIR="$HOME/.nvm"
    . "$NVM_DIR/nvm.sh"
    nvm use $NODE_VERSION

    echo "Artifact => $ARTIFACT_FILE"

    echo "Build code-server ===>"
    time npm run build
    echo "<====================="

    echo "Build vscode ===>"
    time npm run build:vscode
    echo "<====================="

    echo "Build release package ===>"
    time npm run release
    time npm run release:standalone
    time npm run test:integration
    time npm run package
    echo "<=========================="

    echo Build completed at `date`
    echo "<=========================="

}

post_build_phase() {

    echo "Uploading artifact ===>"
    S3_KEY="$ARTIFACT_PREFIX/$ARTIFACT_FILE"
    echo "Uploading $S3_KEY to S3..."
    aws s3 cp release-packages/$ARTIFACT_FILE s3://$ARTIFACT_BUCKET/$S3_KEY
    echo "<======================="

    echo "Extracting and uploading static files ===>"
    TEMP_DIR=$(mktemp -d)
    tar -xzf release-packages/$ARTIFACT_FILE -C $TEMP_DIR

    echo "Upload vscode static files ===>"
    STATIC_S3_KEY="$STATIC_ARTIFACT_PREFIX/stable-$CODEBUILD_SOURCE_VERSION/static"
    SOURCE_DIR="$TEMP_DIR/$ARTIFACT_NAME/lib/vscode"
    aws s3 cp $SOURCE_DIR/out s3://$ARTIFACT_BUCKET/$STATIC_S3_KEY/out --recursive
    aws s3 cp $SOURCE_DIR/node_modules s3://$ARTIFACT_BUCKET/$STATIC_S3_KEY/node_modules --recursive
    echo "<======================="

    echo "Upload code-server static files ===>"
    STATIC_S3_KEY="$STATIC_ARTIFACT_PREFIX/stable-$CODEBUILD_SOURCE_VERSION/_static"
    SOURCE_DIR="$TEMP_DIR/$ARTIFACT_NAME"
    aws s3 cp $SOURCE_DIR/out s3://$ARTIFACT_BUCKET/$STATIC_S3_KEY/out --recursive
    aws s3 cp $SOURCE_DIR/node_modules s3://$ARTIFACT_BUCKET/$STATIC_S3_KEY/node_modules --recursive
    aws s3 cp $SOURCE_DIR/src s3://$ARTIFACT_BUCKET/$STATIC_S3_KEY/src --recursive
    echo "<======================="

    echo "Pruning old artifacts ===>"
    echo "Keeping last $MAX_ARTIFACTS artifacts in s3://$ARTIFACT_BUCKET/$ARTIFACT_PREFIX"

    OBJECTS=$(aws s3api list-objects-v2 \
    --bucket "$ARTIFACT_BUCKET" \
    --prefix "$ARTIFACT_PREFIX/" \
    | jq -r '.Contents | sort_by(.LastModified) | .[] | select(.Key != "'$ARTIFACT_PREFIX/'") | .Key')

    echo "Artifact list =>"
    echo $OBJECTS
    echo "<==============="

    TOTAL_OBJECTS=$(echo "$OBJECTS" | wc -l)
    echo "Total artifacts found: $TOTAL_OBJECTS"

    if (( $TOTAL_OBJECTS > $MAX_ARTIFACTS )); then
        TO_DELETE=$(( $TOTAL_OBJECTS - $MAX_ARTIFACTS ))
        echo "Pruning $TO_DELETE oldest artifacts..."

        echo "$OBJECTS" | head -n $TO_DELETE | awk '{print $1}' | while read -r KEY; do
            echo "Deleting: s3://$ARTIFACT_BUCKET/$KEY"
            aws s3 rm "s3://$ARTIFACT_BUCKET/$KEY"
        done
    else
        echo "No pruning needed."
    fi

    echo "<============================"

    echo "Pruning old static artifacts ===>"
    echo "Keeping last $MAX_ARTIFACTS artifacts in s3://$ARTIFACT_BUCKET/$STATIC_ARTIFACT_PREFIX"

    OBJECTS=$(aws s3api list-objects-v2 \
    --bucket "$ARTIFACT_BUCKET" \
    --prefix "$STATIC_ARTIFACT_PREFIX/" \
    --delimiter "/" \
    | jq -r '.CommonPrefixes // [] | .[].Prefix' | while read -r prefix; do
        aws s3api list-objects-v2 \
            --bucket "$ARTIFACT_BUCKET" \
            --prefix "$prefix" \
            --max-items 1 \
        | jq -r '.Contents[0].LastModified + " " + "'$prefix'"'
    done | sort | cut -d' ' -f2-)

    echo "<============================"

}

$1
