
#' Restore a Project
#'
#' Restore a project's dependencies from a lockfile, as previously generated by
#' [snapshot()].
#'
#' @inherit renv-params
#'
#' @param library The library paths to be used during restore. See **Library**
#'   for details.
#'
#' @param lockfile The lockfile to be used for restoration of the associated
#'   project. When `NULL`, the most recently generated lockfile for this project
#'   is used.
#'
#' @param repos The repositories to use during restore, for packages installed
#'   from CRAN or another similar R package repository. When set, this will
#'   override any repositories declared in the lockfile. See also the
#'   `repos.override` option in [config] for an alternate way to provide a
#'   repository override.
#'
#' @param clean Boolean; remove packages not recorded in the lockfile from
#'   the target library? Use `clean = TRUE` if you'd like the library state
#'   to exactly reflect the lockfile contents after `restore()`.
#'
#' @return A named list of package records which were installed by `renv`.
#'
#' @section Library:
#'
#' When `renv::restore()` is called, packages from the lockfile are compared
#' against packages currently installed in the library paths specified by
#' `library`. Any packages which have changed will then be installed into the
#' default library. If `clean = TRUE`, then packages that exist within the
#' default library, but aren't recorded in the lockfile, will be removed as
#' well.
#'
#' @family reproducibility
#'
#' @export
#'
#' @example examples/examples-init.R
restore <- function(project  = NULL,
                    ...,
                    library  = NULL,
                    lockfile = NULL,
                    repos    = NULL,
                    clean    = FALSE,
                    confirm  = interactive())
{
  renv_consent_check()
  renv_scope_error_handler()

  project  <- project %||% renv_project()
  library  <- library %||% renv_libpaths_all()
  lockfile <- lockfile %||% renv_lockfile_load(project = project)

  # activate the requested library
  ensure_directory(library)
  renv_scope_libpaths(library)

  # perform Python actions on exit
  on.exit(renv_python_restore(project), add = TRUE)

  # resolve the lockfile
  if (is.character(lockfile))
    lockfile <- renv_lockfile_read(lockfile)

  # inject overrides (if any)
  lockfile <- renv_lockfile_override(lockfile)

  # override repositories if requested
  repos <- repos %||%
    renv_config("repos.override") %||%
    lockfile$R$Repositories

  if (length(repos))
    renv_scope_options(repos = convert(repos, "character"))

  # get records for R packages currently installed
  current <- snapshot(project = project,
                      library = library,
                      lockfile = NULL,
                      type = "simple")

  # compare lockfile vs. currently-installed packages
  diff <- renv_lockfile_diff_packages(current, lockfile)

  # don't remove packages unless 'clean = TRUE'
  diff <- renv_vector_diff(diff, if (!clean) "remove")

  # only remove packages from the project library
  difflocs <- map_chr(names(diff), function(package) {
    find.package(package, lib.loc = library, quiet = TRUE) %||% ""
  })

  exclude <- diff == "remove" & dirname(difflocs) != library[[1]]
  diff <- diff[!exclude]

  # don't take any actions with ignored packages
  ignored <- renv_project_ignored_packages(project = project)
  diff <- diff[renv_vector_diff(names(diff), ignored)]

  if (!length(diff)) {
    name <- if (!missing(library)) "library" else "project"
    vwritef("* The %s is already synchronized with the lockfile.", name)
    return(invisible(diff))
  }

  if (!renv_restore_preflight(project, library, diff, current, lockfile, confirm)) {
    message("* Operation aborted.")
    return(FALSE)
  }

  if (confirm || renv_verbose())
    renv_restore_report_actions(diff, current, lockfile)

  if (confirm && !proceed()) {
    message("* Operation aborted.")
    return(invisible(diff))
  }

  # perform the restore
  records <- renv_restore_run_actions(project, diff, current, lockfile)
  invisible(records)
}

renv_restore_run_actions <- function(project, actions, current, lockfile) {

  packages <- names(actions)

  renv_restore_begin(
    project = project,
    records = renv_records(lockfile),
    packages = packages
  )

  on.exit(renv_restore_end(), add = TRUE)

  # first, handle package removals
  removes <- actions[actions == "remove"]
  enumerate(removes, function(package, action) {
    renv_restore_remove(project, package, current)
  })

  # next, handle installs
  installs <- actions[actions != "remove"]
  packages <- names(installs)

  # perform the install
  library <- renv_libpaths_default()
  records <- renv_retrieve(packages)
  status <- renv_install(records, library)

  # detect dependency tree repair
  diff <- renv_lockfile_diff_packages(renv_records(lockfile), records)
  diff <- diff[diff != "remove"]
  if (!empty(diff)) {
    renv_pretty_print_records(
      records[names(diff)],
      "The dependency tree was repaired during package installation:",
      "Call `renv::snapshot()` to capture these dependencies in the lockfile."
    )
  }

  # check installed packages and prompt for reload if needed
  renv_install_postamble(names(records))

  # return status
  invisible(records)

}

renv_restore_state <- function() {
  renv_global_get("restore.state")
}

renv_restore_begin <- function(project = NULL,
                               records = NULL,
                               packages = NULL,
                               handler = NULL,
                               rebuild = NULL,
                               recursive = TRUE)
{

  renv_global_set("restore.state", env(

    # the active project (if any) used for restore
    project = project,

    # the package records used for restore, providing information
    # on the packages to be installed (their version, source, etc)
    records = records,

    # the set of packages to be installed in this restore session;
    # as explicitly requested by the user / front-end API call
    packages = packages,

    # an optional handler, to be used during retrieve / restore
    handler = handler %||% function(package, action) action,

    # packages which should be rebuilt (skipping the cache)
    rebuild = rebuild,

    # should package dependencies be crawled recursively? this is useful if
    # the records list is incomplete and needs to be built as packages are
    # downloaded
    recursive = recursive,

    # packages which we have attempted to retrieve
    retrieved = new.env(parent = emptyenv()),

    # packages which need to be installed
    install = stack(),

    # a collection of the requirements imposed on dependent packages
    # as they are discovered
    requirements = new.env(parent = emptyenv())

  ))

}

renv_restore_end <- function() {
  renv_global_clear("restore.state")
}

# nocov start

renv_restore_report_actions <- function(actions, current, lockfile) {

  if (!renv_verbose() || empty(actions))
    return(invisible(NULL))

  lhs <- renv_records(current)
  rhs <- renv_records(lockfile)
  renv_pretty_print_records_pair(
    lhs[names(lhs) %in% names(actions)],
    rhs[names(rhs) %in% names(actions)],
    "The following package(s) will be updated:"
  )

}

# nocov end

renv_restore_remove <- function(project, package, lockfile) {
  records <- renv_records(lockfile)
  record <- records[[package]]
  vwritef("Removing %s [%s] ...", package, record$Version)
  paths <- renv_paths_library(project = project, package)
  recursive <- renv_file_type(paths) == "directory"
  unlink(paths, recursive = recursive)
  vwritef("\tOK (removed from library)")
  TRUE
}

renv_restore_preflight <- function(project, library, actions, current, lockfile, confirm) {
  records <- renv_records(lockfile)
  matching <- keep(records, names(actions))
  renv_install_preflight(project, library, matching, confirm)
}

renv_restore_find <- function(record) {

  # skip packages whose installation was explicitly requested
  state <- renv_restore_state()
  if (record$Package %in% state$packages)
    return("")

  # need to restore if it's not yet installed
  libpaths <- renv_global_get("library.paths") %||% renv_libpaths_all()
  for (library in libpaths) {
    path <- renv_restore_find_impl(record, library)
    if (nzchar(path))
      return(path)
  }

  ""

}

renv_restore_find_impl <- function(record, library) {

  path <- file.path(library, record$Package)
  if (!file.exists(path))
    return("")

  # attempt to read DESCRIPTION
  current <- catch(as.list(renv_description_read(path)))
  if (inherits(current, "error"))
    return("")

  # check for matching records
  source <- tolower(record$Source %||% "")
  if (!nzchar(source))
    return("")

  # check for an up-to-date version from R package repository
  if (source %in% c("cran", "repository")) {
    fields <- c("Package", "Version")
    if (identical(record[fields], current[fields]))
      return(path)
  }

  # otherwise, match on remote fields
  fields <- renv_record_names(record, c("Package", "Version"))
  if (identical(record[fields], current[fields]))
    return(path)

  # failed to match; return empty path
  ""

}

renv_restore_rebuild_required <- function(record) {
  state <- renv_restore_state()
  any(c(NA_character_, record$Package) %in% state$rebuild)
}
