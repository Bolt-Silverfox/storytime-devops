terraform {
  # >= 1.11 for use_lockfile (S3-native state locking, no DynamoDB table).
  # >= 1.4 for the built-in terraform_data resource used by guards.tf.
  required_version = ">= 1.11.0"

  required_providers {
    aws = {
      source  = "hashicorp/aws"
      version = "~> 5.40"
    }
    cloudflare = {
      source  = "cloudflare/cloudflare"
      version = "~> 4.40"
    }
    tls = {
      source  = "hashicorp/tls"
      version = "~> 4.0"
    }
  }

  # ---------------------------------------------------------------------------
  # Remote state in S3. Shared, durable, versioned; survives losing a checkout.
  # Locking uses S3 conditional writes (use_lockfile), so there is no DynamoDB
  # lock table.
  #
  # This bucket is DELIBERATELY NOT MANAGED BY THIS CONFIG — a config cannot
  # safely create the bucket that stores its own state. Bootstrap it out of band
  # exactly once; see infra/README.md -> "Remote state".
  #
  # NOTE: it is NOT `fateround-tfstate`. Storytime has its own bucket, in its
  # own region, so the two projects never share state or a blast radius.
  #
  # Workspace layout in the bucket:
  #   infra/terraform.tfstate               # default workspace (unused)
  #   env:/shared/infra/terraform.tfstate   # account-global resources
  #   env:/dev/infra/terraform.tfstate
  #   env:/staging/infra/terraform.tfstate
  #   env:/blue/infra/terraform.tfstate
  #   env:/prod/infra/terraform.tfstate
  # ---------------------------------------------------------------------------
  backend "s3" {
    bucket       = "storytime-tfstate"
    key          = "infra/terraform.tfstate"
    region       = "eu-west-1"
    encrypt      = true
    use_lockfile = true
  }
}
