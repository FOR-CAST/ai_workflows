library(targets)
list(
  tar_target(beta_only, 42),
  tar_target(beta_consumer, beta_only + 1)
)
