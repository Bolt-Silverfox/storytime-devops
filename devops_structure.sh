#!/bin/bash

# Create directories
mkdir -p infra/terraform/modules/vpc
mkdir -p infra/terraform/modules/ecs
mkdir -p infra/terraform/modules/rds
mkdir -p infra/terraform/modules/ecr
mkdir -p infra/terraform/envs/dev
mkdir -p infra/terraform/envs/staging
mkdir -p infra/terraform/envs/prod

mkdir -p ci-cd/mobile
mkdir -p ci-cd/frontend
mkdir -p ci-cd/backend
mkdir -p ci-cd/shared

mkdir -p docs
mkdir -p scripts

# Create placeholder files
touch infra/terraform/modules/vpc/README.md
touch infra/terraform/modules/ecs/README.md
touch infra/terraform/modules/rds/README.md
touch infra/terraform/modules/ecr/README.md

touch infra/terraform/envs/dev/README.md
touch infra/terraform/envs/staging/README.md
touch infra/terraform/envs/prod/README.md

echo "# Root Terraform Config" > infra/terraform/main.tf

touch ci-cd/mobile/README.md
touch ci-cd/frontend/README.md
touch ci-cd/backend/README.md
touch ci-cd/shared/README.md

touch docs/environments.md
touch docs/deployment-guide.md
touch docs/ci-cd-overview.md
touch docs/infra-architecture.md

echo "#!/bin/bash" > scripts/build.sh
echo "#!/bin/bash" > scripts/deploy.sh
echo "#!/bin/bash" > scripts/setup-dev-env.sh

