# Storytime DevOps

This repository contains all DevOps, CI/CD, and infrastructure automation for the Storytime platform.

It supports the following services:
- `storytime-mobile` (Expo React Native)
- `storytime-fe` (Next.js frontend)
- `storytime-be` (NestJS backend)

---

##  Purpose

This repo centralizes:

- Infrastructure as Code (Terraform for AWS)
- GitHub Actions CI/CD pipelines
- Deployment automation scripts
- Documentation for environments and deployment processes

All DevOps-related configuration for the entire Storytime ecosystem lives here.

---

##  Getting Started

Clone the repository:

```bash
git clone <devops-repo-url>
cd storytime-devops



Install basic prerequisites for DevOps (you likely already have most):

- Git
- Docker
- AWS CLI
- Terraform (will be used for IaC)
- Bash shell (for automation scripts)

##  Project Structure
infra/
  └── terraform/
      ├── modules/
      │   ├── vpc/
      │   ├── ecs/
      │   ├── rds/
      │   └── ecr/
      ├── envs/
      │   ├── dev/
      │   ├── staging/
      │   └── prod/
      └── main.tf

ci-cd/
  ├── mobile/
  ├── frontend/
  ├── backend/
  └── shared/

docs/
  ├── environments.md
  ├── deployment-guide.md
  ├── ci-cd-overview.md
  └── infra-architecture.md

scripts/
  ├── build.sh
  ├── deploy.sh
  └── setup-dev-env.sh
