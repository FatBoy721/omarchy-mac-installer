# Package build boundary

The source prepared here is a set of ordinary Arch package recipes and pinned source overlays. `prepare` materializes them from the immutable package-recipe commit into a new directory; it does not invoke a build system. Build those prepared directories with `makepkg` in an appropriate aarch64 Arch Linux environment. This keeps the central installer checkout as the source of the J714s integration while leaving package artifacts and image production to their established builders.

For Mesa specifically, `mesa/j714s-gpu.env` is installed by the recipe as an environment file so the candidate's `ASAHI_M5_BRINGUP=1` setting applies to the system session. This source configuration and a successful package build do not qualify native GPU rendering or the combined normal boot chain.

Do not publish these recipes or artifacts, promote them to a package channel, or treat a successful build as hardware qualification. Preserve the source commit, source-tree hashes, `.BUILDINFO`, `.PKGINFO`, package hashes and build logs when a later authorized builder produces artifacts. Verify the resulting architecture, dependencies, ELF targets and matching kernel/Mesa UAPI before passing packages to the normal authenticated candidate/image producer.
