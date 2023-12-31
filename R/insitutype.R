#' Run insitutype.
#'
#' A wrapper for nbclust, to manage subsampling and multiple random starts.
#' @param x Counts matrix (or dgCMatrix), cells * genes.
#'
#'   Alternatively, a \linkS4class{SingleCellExperiment} object containing such
#'   a matrix.
#' @param neg Vector of mean negprobe counts per cell
#' @param bg Expected background
#' @param anchors Vector giving "anchor" cell types, for use in semi-supervised
#'   clustering. Vector elements will be mainly NA's (for non-anchored cells)
#'   and cell type names for cells to be held constant throughout iterations.
#' @param cohort Vector of cells' cohort memberships
#' @param n_clusts Number of clusters, in addition to any pre-specified cell
#'   types. Enter 0 to run purely supervised cell typing from fixed profiles.
#'   Enter a range of integers to automatically select the optimal number of
#'   clusters.
#' @param reference_profiles Matrix of expression profiles of pre-defined
#'   clusters, e.g. from previous scRNA-seq. These profiles will not be updated
#'   by the EM algorithm. Colnames must all be included in the init_clust
#'   variable.
#' @param update_reference_profiles Logical, for whether to use the data to
#'   update the reference profiles. Default and strong recommendation is TRUE.
#'   (However, if the reference profiles are from the same platform as the
#'   study, then FALSE could be better.)
#' @param sketchingdata Optional matrix of data for use in non-random sampling
#'   via "sketching". If not provided, then the data's first 20 PCs will be
#'   used.
#' @param align_genes Logical, for whether to align the counts matrix and the
#'   fixed_profiles by gene ID.
#' @param nb_size The size parameter to assume for the NB distribution.
#' @param init_clust Vector of initial cluster assignments. If NULL, initial
#'   assignments will be automatically inferred.
#' @param n_starts the number of iterations
#' @param n_benchmark_cells the number of cells for benchmarking
#' @param n_phase1 Subsample size for phase 1 (random starts)
#' @param n_phase2 Subsample size for phase 2 (refining in a larger subset)
#' @param n_phase3 Subsample size for phase 3 (getting final solution in a very
#'   large subset)
#' @param n_chooseclusternumber Subsample size for choosing an optimal number of
#'   clusters
#' @param pct_drop the decrease in percentage of cell types with a valid
#'   switchover to another cell type compared to the last iteration. Default
#'   value: 1/10000. A valid switchover is only applicable when a cell has
#'   changed the assigned cell type with its highest cell type probability
#'   increased by min_prob_increase.
#' @param min_prob_increase the threshold of probability used to determine a
#'   valid cell type switchover
#' @param max_iters Maximum number of iterations.
#' @param n_anchor_cells For semi-supervised learning. Maximum number of anchor
#'   cells to use for each cell type.
#' @param min_anchor_cosine For semi-supervised learning. Cells must have at
#'   least this much cosine similarity to a fixed profile to be used as an
#'   anchor.
#' @param min_anchor_llr For semi-supervised learning. Cells must have
#'   (log-likelihood ratio / totalcounts) above this threshold to be used as an
#'   anchor
#' @param insufficient_anchors_thresh Cell types that end up with fewer than
#'   this many anchors after anchor selection will be discarded.
#' @param ... For the \linkS4class{SingleCellExperiment} method, additional
#'   arguments to pass to the ANY method.
#' @param assay.type A string specifying which assay values to use.
#' @return A list, with the following elements: \enumerate{ \item clust: a
#'   vector given cells' cluster assignments \item prob: a vector giving the
#'   confidence in each cell's cluster \item logliks: Matrix of cells'
#'   log-likelihoods under each cluster. Cells in rows, clusters in columns.
#'   \item profiles: a matrix of cluster-specific expression profiles \item
#'   anchors: from semi-supervised clustering: a vector giving the identifies
#'   and cell types of anchor cells }
#'
#' @name insitutype
#' @examples 
#' options(mc.cores = 1)
#' data("mini_nsclc")
#' unsup <- insitutype(
#'  x = mini_nsclc$counts,
#'  neg = Matrix::rowMeans(mini_nsclc$neg),
#'  n_clusts = 8,
#'  n_phase1 = 200,
#'  n_phase2 = 500,
#'  n_phase3 = 2000,
#'  n_starts = 1,
#'  max_iters = 5
#' ) # choosing inadvisably low numbers to speed the vignette; using the defaults in recommended.
#' table(unsup$clust)
NULL

#' @importFrom stats lm
#' @importFrom Matrix rowMeans
#' @importFrom Matrix colSums
#' @importFrom Matrix t
.insitutype <- function(x,
                       neg,
                       bg = NULL,
                       anchors = NULL,
                       cohort = NULL,
                       n_clusts,
                       reference_profiles = NULL,
                       update_reference_profiles = TRUE,
                       sketchingdata = NULL,
                       align_genes = TRUE,
                       nb_size = 10,
                       init_clust = NULL,
                       n_starts = 10,
                       n_benchmark_cells = 10000,
                       n_phase1 = 10000,
                       n_phase2 = 20000,
                       n_phase3 = 100000,
                       n_chooseclusternumber = 2000,
                       pct_drop = 1 / 10000,
                       min_prob_increase = 0.05,
                       max_iters = 40,
                       n_anchor_cells = 2000,
                       min_anchor_cosine = 0.3,
                       min_anchor_llr = 0.03,
                       insufficient_anchors_thresh = 20) {
  
  
  #### preliminaries ---------------------------
  
  if (any(rowSums(x) == 0)) {
    stop("Cells with 0 counts were found. Please remove.")
  }
  
  ## get neg in condition 
  if (is.null(names(neg))) {
    names(neg) <- rownames(x)
  }
  if (length(neg) != nrow(x)) {
    stop("length of neg should equal nrows of counts.")
  }
  
  if (is.null(cohort)) {
    cohort <- rep("all", length(neg))
  }
  
  ### infer bg if not provided: assume background is proportional to the scaling factor s
  if (is.null(bg)) {
    s <- Matrix::rowMeans(x)
    bgmod <- stats::lm(neg ~ s - 1)
    bg <- bgmod$fitted
    names(bg) <- rownames(x)
  }
  if (length(bg) == 1) {
    bg <- rep(bg, nrow(x))
    names(bg) <- rownames(x)
  }
  
  #### update reference profiles ----------------------------------
  fixed_profiles <- NULL
  if (!is.null(reference_profiles)) {
    if (update_reference_profiles) {
      update_result <- updateReferenceProfiles(reference_profiles,
                                               counts = x, 
                                               neg = neg,
                                               bg = bg,
                                               nb_size = nb_size,
                                               anchors = anchors,
                                               n_anchor_cells = n_anchor_cells, 
                                               min_anchor_cosine = min_anchor_cosine, 
                                               min_anchor_llr = min_anchor_llr)
      fixed_profiles <- update_result$updated_profiles
      anchors <- update_result$anchors
    } else {
      fixed_profiles <- reference_profiles
    }
  }
  # align the genes from fixed_profiles and counts
  if (align_genes && !is.null(fixed_profiles)) {
    sharedgenes <- intersect(rownames(fixed_profiles), colnames(x))
    lostgenes <- setdiff(colnames(x), rownames(fixed_profiles))
    
    # subset to only the shared genes:
    x <- x[, sharedgenes]
    fixed_profiles <- fixed_profiles[sharedgenes, ]
    
    # warn about genes being lost:
    if ((length(lostgenes) > 0) && length(lostgenes < 50)) {
      message(paste0("The following genes in the count data are missing from fixed_profiles and will be omitted from clustering: ",
                     paste0(lostgenes, collapse = ",")))
    }
    if (length(lostgenes) > 50) {
      message(paste0(length(lostgenes), " genes in the count data are missing from fixed_profiles and will be omitted from clustering"))
    }
  }

  
  #### set up subsetting: ---------------------------------
  # get data for subsetting if not already provided
  # (e.g., if PCA is the choice, then point to existing PCA results, and run PCA if not available
  if (!is.null(sketchingdata)) {
    # check that it's correct:
    if (nrow(sketchingdata) != nrow(x)) {
      warning("counts and sketchingdata have different numbers of row. Discarding sketchingdata.")
      sketchingdata <- NULL
    }
  }
  if (is.null(sketchingdata)) {
    sketchingdata <- prepDataForSketching(x)
  }
  n_phase1 <- min(n_phase1, nrow(x))
  n_phase2 <- min(n_phase2, nrow(x))
  n_phase3 <- min(n_phase3, nrow(x))
  n_benchmark_cells <- min(n_benchmark_cells, nrow(x))
  
  # define sketching "Plaids" (rough clusters) for subsampling:
  plaid <- geoSketch_get_plaid(X = sketchingdata, 
                                N = min(n_phase1, n_phase2, n_phase3, n_benchmark_cells),
                                alpha=0.1,
                                max_iter=200,
                                returnBins=FALSE,
                                minCellsPerBin = 1)
  
  #### choose cluster number: -----------------------------
  if (!is.null(init_clust)) {
    if (!is.null(n_clusts)) {
      message("init_clust was specified; this will overrule the n_clusts argument.")
    }
    n_clusts <- length(setdiff(unique(init_clust), colnames(fixed_profiles)))
  }
  if (is.null(n_clusts)) {
    n_clusts <- 5:15 + 5 * (is.null(fixed_profiles))
  }
  # get optimal number of clusters
  if (length(n_clusts) > 1) {
    
    message("Selecting optimal number of clusters from a range of ", min(n_clusts), " - ", max(n_clusts))

    chooseclusternumber_subset <- geoSketch_sample_from_plaids(Plaid = plaid, 
                                                               N = min(n_chooseclusternumber, nrow(x)))
    
    n_clusts <- chooseClusterNumber(
      counts = x[chooseclusternumber_subset, ], 
      neg = neg[chooseclusternumber_subset], 
      bg = bg[chooseclusternumber_subset], 
      fixed_profiles = reference_profiles,
      init_clust = NULL, 
      n_clusts = n_clusts,
      max_iters = max(max_iters, 20),
      subset_size = length(chooseclusternumber_subset), 
      align_genes = TRUE, plotresults = FALSE, nb_size = nb_size)$best_clust_number 
  }
  
  #### phase 1: many random starts in small subsets -----------------------------
  
  if (!is.null(init_clust)) {
    message("init_clust was provided, so phase 1 - random starts in small subsets - will be skipped.")
    
    tempprofiles <- sapply(by(x[!is.na(init_clust), ], init_clust[!is.na(init_clust)], colMeans), cbind)
    rownames(tempprofiles) <- colnames(x)
    
  } else {
    message(paste0("phase 1: random starts in ", n_phase1, " cell subsets"))
    
    # get a list in which each element is the cell IDs to be used in a subset
    random_start_subsets <- list()
    for (i in 1:n_starts) {
      random_start_subsets[[i]] <- geoSketch_sample_from_plaids(Plaid = plaid, 
                                                                 N = min(n_phase1, nrow(x)))
    }
    
    # get a vector of cells IDs to be used in comparing the random starts:
    benchmarking_subset <- geoSketch_sample_from_plaids(Plaid = plaid, 
                                                        N = min(n_benchmark_cells, nrow(x)))

    # run nbclust from each of the random subsets, and save the profiles:
    profiles_from_random_starts <- list()
    for (i in 1:n_starts) {

      cluster_name_pool <- c(letters, paste0(rep(letters, each = 26), rep(letters, 26)))
      tempinit <- rep(cluster_name_pool[seq_len(n_clusts)], each = ceiling(length(random_start_subsets[[i]]) / n_clusts))[
        seq_along(random_start_subsets[[i]])]
     
      profiles_from_random_starts[[i]] <- nbclust(
        counts = x[random_start_subsets[[i]], ], 
        neg = neg[random_start_subsets[[i]]], 
        bg = bg[random_start_subsets[[i]]],
        fixed_profiles = fixed_profiles,
        cohort = cohort[random_start_subsets[[i]]],
        init_profiles = NULL,
        init_clust = tempinit, 
        nb_size = nb_size,
        pct_drop = 1/500,
        min_prob_increase = min_prob_increase,
        max_iters = max(max_iters, 20),
      )$profiles
    }
    
    # find which profile matrix does best in the benchmarking subset:
    benchmarking_logliks <- c()
    for (i in 1:n_starts) {
      templogliks <- parallel::mclapply(asplit(profiles_from_random_starts[[i]], 2),
                        lldist,
                        mat = x[benchmarking_subset, ],
                        bg = bg[benchmarking_subset],
                        size = nb_size,
                        mc.cores = numCores())
      templogliks <- do.call(cbind, templogliks)
      # take the sum of cells' best logliks:
      benchmarking_logliks[i] <- sum(apply(templogliks, 1, max))
    }
    best_start <- which.max(benchmarking_logliks)
    tempprofiles <- profiles_from_random_starts[[best_start]]
    
    rm(profiles_from_random_starts)
    rm(templogliks)
  }
  
  #### phase 2: -----------------------------------------------------------------
  message(paste0("phase 2: refining best random start in a ", n_phase2, " cell subset"))
  phase2_sample <- geoSketch_sample_from_plaids(Plaid = plaid, 
                                                N = min(n_phase2, nrow(x)))
  
  # get initial cell type assignments:
  temp_init_clust <- NULL
  if (!is.null(init_clust)) {
    temp_init_clust <- init_clust[phase2_sample]
    tempprofiles <- NULL
  }
  
  # run nbclust, initialized with the cell type assignments derived from the previous phase's profiles
  clust2 <- nbclust(counts = x[phase2_sample, ], 
                    neg = neg[phase2_sample], 
                    bg = bg[phase2_sample],
                    fixed_profiles = fixed_profiles,
                    cohort = cohort[phase2_sample],
                    init_profiles = tempprofiles, 
                    init_clust = temp_init_clust, 
                    nb_size = nb_size,
                    pct_drop = 1/1000,
                    min_prob_increase = min_prob_increase,
                    max_iters = max_iters)
  tempprofiles <- clust2$profiles
 
  #### phase 3: -----------------------------------------------------------------
  message(paste0("phase 3: finalizing clusters in a ", n_phase3, " cell subset"))
  
  phase3_sample <- geoSketch_sample_from_plaids(Plaid = plaid, 
                                                N = min(n_phase3, nrow(x)))
  
  # run nbclust, initialized with the cell type assignments derived from the previous phase's profiles
  clust3 <- nbclust(counts = x[phase3_sample, ], 
                    neg = neg[phase3_sample], 
                    bg = bg[phase3_sample],
                    fixed_profiles = fixed_profiles,
                    cohort = cohort[phase3_sample],
                    init_profiles = tempprofiles, 
                    init_clust = NULL,  
                    nb_size = nb_size,
                    pct_drop = pct_drop,
                    min_prob_increase = min_prob_increase,
                    max_iters = max_iters)
  profiles <- clust3$profiles
  

  #### phase 4: -----------------------------------------------------------------
  message(paste0("phase 4: classifying all ", nrow(x), " cells"))
  
  out <- insitutypeML(x = x, 
                      neg = neg, 
                      bg = bg, 
                      reference_profiles = profiles, 
                      cohort = cohort,
                      nb_size = nb_size, 
                      align_genes = TRUE) 
  out$anchors <- anchors
  
  return(out)
}

############################
# S4 method definitions 
############################

#' @export
#' @rdname insitutype
setGeneric("insitutype", function(x, ...) standardGeneric("insitutype"))

#' @export
#' @rdname insitutype
setMethod("insitutype", "ANY", .insitutype)

#' @export
#' @rdname insitutype
#' @importFrom SummarizedExperiment assay
#' @importFrom SingleCellExperiment SingleCellExperiment
setMethod("insitutype", "SingleCellExperiment", function(x, ..., assay.type="counts") {
  .insitutype(t(assay(x, i=assay.type)), ...)
})

