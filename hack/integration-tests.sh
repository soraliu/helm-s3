#!/usr/bin/env bash
set -euo pipefail

# NOTE:
# For helm v2, the command is `helm search foo/bar`
# For helm v3, the command is `helm search repo foo/bar`
search_arg=""
IT_HELM_VERSION="${IT_HELM_VERSION:-}"
if [ "${IT_HELM_VERSION:0:1}" == "3" ]; then
  search_arg="repo"
fi

set -x

# Set up
BUCKET="test-bucket/charts"
CONTENT_TYPE="application/x-gzip"
MINIO="helm-s3-minio/${BUCKET}"
PUBLISH_URI="http://example.com/charts"
REPO="test-repo"
S3_URI="s3://${BUCKET}"
TEST_CASE=""

function cleanup() {
    rc=$?
    set +x
    rm -f postgresql-0.8.3.tgz
    helm repo remove "${REPO}" &>/dev/null

    if [[ ${rc} -eq 0 ]]; then
        echo -e "\nAll tests passed!"
    else
        echo -e "\nTest failed: ${TEST_CASE}"
    fi
}

trap cleanup EXIT

# Prepare chart to play with.
helm fetch stable/postgresql --version 0.8.3
#
# Test: init repo
#

helm s3 init s3://test-bucket/charts
if [ $? -ne 0 ]; then
    echo "Failed to initialize repo"
    exit 1
fi

mc ls helm-s3-minio/test-bucket/charts/index.yaml
if [ $? -ne 0 ]; then
    echo "Repository was not actually initialized"
    exit 1
fi

helm repo add test-repo s3://test-bucket/charts
if [ $? -ne 0 ]; then
    echo "Failed to add repo"
    exit 1
fi

#
# Test: push chart
#

helm s3 push postgresql-0.8.3.tgz test-repo
if [ $? -ne 0 ]; then
    echo "Failed to push chart to repo"
    exit 1
fi

mc ls helm-s3-minio/test-bucket/charts/postgresql-0.8.3.tgz
if [ $? -ne 0 ]; then
    echo "Chart was not actually uploaded"
    exit 1
fi

helm search ${search_arg} test-repo/postgres | grep -q 0.8.3
if [ $? -ne 0 ]; then
    echo "Failed to find uploaded chart"
    exit 1
fi

#
# Test: push the same chart again
#

set +e # next command should return non-zero status

helm s3 push postgresql-0.8.3.tgz test-repo
if [ $? -eq 0 ]; then
    echo "The same chart must not be pushed again"
    exit 1
fi

set -e

helm s3 push --force postgresql-0.8.3.tgz test-repo
if [ $? -ne 0 ]; then
    echo "The same chart must be pushed again using --force"
    exit 1
fi

#
# Test: fetch chart
#

helm fetch test-repo/postgresql --version 0.8.3
if [ $? -ne 0 ]; then
    echo "Failed to fetch chart from repo"
    exit 1
fi

#
# Test: delete chart
#

helm s3 delete postgresql --version 0.8.3 test-repo
if [ $? -ne 0 ]; then
    echo "Failed to delete chart from repo"
    exit 1
fi

if mc ls -q helm-s3-minio/test-bucket/charts/postgresql-0.8.3.tgz 2>/dev/null ; then
    echo "Chart was not actually deleted"
    exit 1
fi

if helm search ${search_arg} test-repo/postgres | grep -q 0.8.3 ; then
    echo "Failed to delete chart from index"
    exit 1
fi

#
# Test: push with content-type
#
expected_content_type='application/gzip'
helm s3 push --content-type=${expected_content_type} postgresql-0.8.3.tgz test-repo
if [ $? -ne 0 ]; then
    echo "Failed to push chart to repo"
    exit 1
fi

helm search ${search_arg} test-repo/postgres | grep -q 0.8.3
if [ $? -ne 0 ]; then
    echo "Failed to find uploaded chart"
    exit 1
fi

mc ls helm-s3-minio/test-bucket/charts/postgresql-0.8.3.tgz
if [ $? -ne 0 ]; then
    echo "Chart was not actually uploaded"
    exit 1
fi

actual_content_type=$(mc stat helm-s3-minio/test-bucket/charts/postgresql-0.8.3.tgz | awk '/Content-Type/{print $NF}')
if [ $? -ne 0 ]; then
    echo "failed to stat uploaded chart"
    exit 1
fi

if [ "${expected_content_type}" != "${actual_content_type}" ]; then
    echo "content-type, expected '${expected_content_type}', actual '${actual_content_type}'"
    exit 1
fi

#
# Tear down
#

rm postgresql-0.8.3.tgz
helm repo remove test-repo
set +x

helm repo remove "${REPO}" &>/dev/null || true

TEST_CASE="helm s3 init"
helm s3 init "${S3_URI}"
mc ls "${MINIO}/index.yaml" &>/dev/null
helm repo add "${REPO}" "${S3_URI}"

TEST_CASE="helm s3 push"
helm s3 push postgresql-0.8.3.tgz "${REPO}"
mc ls "${MINIO}/postgresql-0.8.3.tgz" &>/dev/null
helm search "${REPO}/postgres" | grep -q 0.8.3

TEST_CASE="helm s3 push fails"
! helm s3 push postgresql-0.8.3.tgz "${REPO}" 2>/dev/null

TEST_CASE="helm s3 push --force"
helm s3 push --force postgresql-0.8.3.tgz "${REPO}"

TEST_CASE="helm fetch"
helm fetch "${REPO}/postgresql" --version 0.8.3

TEST_CASE="helm s3 reindex --publish <uri>"
helm s3 reindex "${REPO}" --publish "${PUBLISH_URI}"
mc cat "${MINIO}/index.yaml" | grep -Fqw "${PUBLISH_URI}/postgresql-0.8.3.tgz"
mc stat "${MINIO}/index.yaml" | grep "X-Amz-Meta-Helm-S3-Publish-Uri" | grep -Fqw "${PUBLISH_URI}"

TEST_CASE="helm s3 reindex"
helm s3 reindex "${REPO}"
mc cat "${MINIO}/index.yaml" | grep -Fqw "${S3_URI}/postgresql-0.8.3.tgz"
mc stat "${MINIO}/index.yaml" | grep -w "X-Amz-Meta-Helm-S3-Publish-Uri\s*:\s*$"

TEST_CASE="helm s3 delete"
helm s3 delete postgresql --version 0.8.3 "${REPO}"
! mc ls -q "${MINIO}/postgresql-0.8.3.tgz" 2>/dev/null
! helm search "${REPO}/postgres" | grep -Fq 0.8.3

TEST_CASE="helm s3 push --content-type <type>"
helm s3 push --content-type=${CONTENT_TYPE} postgresql-0.8.3.tgz "${REPO}"
helm search "${REPO}/postgres" | grep -Fq 0.8.3
mc ls "${MINIO}/postgresql-0.8.3.tgz" &>/dev/null
mc stat "${MINIO}/postgresql-0.8.3.tgz" | grep "Content-Type" | grep -Fqw "${CONTENT_TYPE}"

# Cleanup to test published repo
helm repo remove "${REPO}"
mc rm --recursive --force "${MINIO}"

TEST_CASE="helm s3 init --publish <uri>"
helm s3 init "${S3_URI}" --publish "${PUBLISH_URI}"
mc ls "${MINIO}/index.yaml" &>/dev/null
mc stat "${MINIO}/index.yaml" | grep "X-Amz-Meta-Helm-S3-Publish-Uri" | grep -Fqw "${PUBLISH_URI}"
helm repo add "${REPO}" "${S3_URI}"

TEST_CASE="helm s3 push (publish)"
helm s3 push postgresql-0.8.3.tgz "${REPO}"
mc ls "${MINIO}/postgresql-0.8.3.tgz" &>/dev/null
mc cat "${MINIO}/index.yaml" | grep -Fqw "${PUBLISH_URI}/postgresql-0.8.3.tgz"
mc stat "${MINIO}/index.yaml" | grep "X-Amz-Meta-Helm-S3-Publish-Uri" | grep -Fqw "${PUBLISH_URI}"
helm search "${REPO}/postgres" | grep -Fq 0.8.3

TEST_CASE="helm fetch (publish)"
helm fetch "${REPO}/postgresql" --version 0.8.3

TEST_CASE="helm s3 delete (publish)"
helm s3 delete postgresql --version 0.8.3 "${REPO}"
mc stat "${MINIO}/index.yaml" | grep "X-Amz-Meta-Helm-S3-Publish-Uri" | grep -Fqw "${PUBLISH_URI}"
! mc ls -q "${MINIO}/postgresql-0.8.3.tgz" 2>/dev/null
! helm search "${REPO}/postgres" | grep -Fq 0.8.3
