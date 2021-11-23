#' Unsupervised and semi-supervised cell typing of single cell expression data.
#'
#' A wrapper for nbclust, to manage subsampling and multiple random starts.
#' @param counts Counts matrix, cells * genes.
#' @param neg Vector of mean negprobe counts per cell
#' @param bg Expected background
#' @param anchors Vector giving "anchor" cell types, for use in semi-supervised clustering. 
#'  Vector elements will be mainly NA's (for non-anchored cells) and cell type names
#'  for cells to be held constant throughout iterations. 
#' @param n_clusts Number of clusters, in addition to any pre-specified cell types.
#'  Enter 0 to run purely supervised cell typing from fixed profiles. 
#'  Enter a range of integers to automatically select the optimal number of clusters. 
#' @param fixed_profiles Matrix of expression profiles of pre-defined clusters,
#'  e.g. from previous scRNA-seq. These profiles will not be updated by the EM algorithm.
#'  Colnames must all be included in the init_clust variable.
#' @param sketchingdata Optional matrix of data for use in non-random sampling via "sketching".
#'  If not provided, then the data's first 20 PCs will be used. 
#' @param align_genes Logical, for whether to align the counts matrix and the fixed_profiles by gene ID.
#' @param nb_size The size parameter to assume for the NB distribution.
#' @param method Whether to run a SEM algorithm (points given a probability
#'   of being in each cluster) or a classic EM algorithm (all points wholly
#'   assigned to one cluster).
#' @param init_clust Vector of initial cluster assignments.
#' If NULL, initial assignments will be automatically inferred.
#' @param n_starts the number of iterations
#' @param n_benchmark_cells the number of cells for benchmarking
#' @param n_phase1 Subsample size for phase 1 (random starts)
#' @param n_phase2 Subsample size for phase 2 (refining in a larger subset)
#' @param n_phase3 Subsample size for phase 3 (getting final solution in a very large subset)
#' @param n_chooseclusternumber Subsample size for choosing an optimal number of clusters
#' @param pct_drop the decrease in percentage of cell types with a valid switchover to 
#'  another cell type compared to the last iteration. Default value: 1/10000. A valid 
#'  switchover is only applicable when a cell has changed the assigned cell type with its
#'  highest cell type probability increased by min_prob_increase. 
#' @param min_prob_increase the threshold of probability used to determine a valid cell 
#'  type switchover
#' @param max_iters Maximum number of iterations.
#' @param n_anchor_cells For semi-supervised learning. Maximum number of anchor cells to use for each cell type. 
#' @param min_anchor_cosine For semi-supervised learning. Cells must have at least this much cosine similarity to a fixed profile to be used as an anchor.
#' @param min_anchor_llr For semi-supervised learning. Cells must have (log-likelihood ratio / totalcounts) above this threshold to be used as an anchor
#' @importFrom stats lm
#' @importFrom Matrix rowMeans
#' @importFrom Matrix colSums
#'
#' @return A list, with the following elements:
#' \enumerate{
#' \item cluster: a vector given cells' cluster assignments
#' \item probs: a matrix of probabilies of all cells (rows) belonging to all clusters (columns)
#' \item profiles: a matrix of cluster-specific expression profiles
#' \item pct_changed: how many cells changed class at each step
#' \item logliks: a matrix of each cell's log-likelihood under each cluster
#' }
#' @export
insitutype <- function(counts, neg, bg = NULL, 
                       anchors = NULL,
                       n_clusts,
                       fixed_profiles = NULL, 
                       sketchingdata = NULL,
                       align_genes = TRUE, nb_size = 10, 
                       method = "CEM", 
                       init_clust = NULL, n_starts = 10, n_benchmark_cells = 50000,
                       n_phase1 = 5000, n_phase2 = 20000, n_phase3 = 100000,
                       n_chooseclusternumber = 2000,
                       pct_drop = 1/10000, min_prob_increase = 0.05, max_iters = 40,
                       n_anchor_cells = 500, min_anchor_cosine = 0.3, min_anchor_llr = 0.01) {
  
  #### preliminaries ---------------------------
  
  if (any(rowSums(counts) == 0)) {
    stop("Cells with 0 counts were found. Please remove.")
  }
  
  # (note: no longer aligning counts matrix to fixed profiles except within the find_anchor_cells function.)
  
  ### infer bg if not provided: assume background is proportional to the scaling factor s
  if (is.null(bg)) {
    s <- Matrix::rowMeans(counts)
    bgmod <- stats::lm(neg ~ s - 1)
    bg <- bgmod$fitted
    names(bg) = rownames(counts)
  }
  if (length(bg) == 1) {
    bg <- rep(bg, nrow(counts))
    names(bg) <- rownames(counts)
  }
  
  #### run purely supervised cell typing if no new clusters are needed -----------------------------
  if (all(n_clusts == 0)) {
    if (is.null(fixed_profiles)) {
      stop("Either set n_clusts > 0 to perform unsupervised clustering or supply a fixed_profiles matrix for supervised classification.")
    }
    
    # align genes:
    sharedgenes <- intersect(rownames(fixed_profiles), colnames(counts))
    lostgenes <- setdiff(colnames(counts), rownames(fixed_profiles))
    
    # subset:
    counts <- counts[, sharedgenes]
    fixed_profiles <- fixed_profiles[sharedgenes, ]
    
    # warn about genes being lost:
    if ((length(lostgenes) > 0) & length(lostgenes < 50)) {
      message(paste0("The following genes in the count data are missing from fixed_profiles and will be omitted from anchor selection: ",
                     paste0(lostgenes, collapse = ",")))
    }
    if (length(lostgenes) > 50) {
      message(paste0(length(lostgenes), " genes in the count data are missing from fixed_profiles and will be omitted from anchor selection"))
    }
    
    # get logliks
    logliks <- apply(fixed_profiles, 2, function(ref) {
      lldist(x = ref,
             mat = counts,
             bg = bg,
             size = nb_size)
    })
    # get remaining outputs
    clust <- colnames(logliks)[apply(logliks, 1, which.max)]
    probs <- logliks2probs(logliks)
    out = list(clust = clust,
               probs = round(probs, 3),
               profiles = fixed_profiles,
               logliks = round(logliks, 3))
    return(out)    
    break()
  }
  
  
  #### select anchor cells if not provided: ------------------------------
  if (is.null(anchors) & !is.null(fixed_profiles)) {
    message("automatically selecting anchor cells with the best fits to fixed profiles")
    anchors <- find_anchor_cells(counts = counts, 
                                 neg = NULL, 
                                 bg = bg, 
                                 profiles = fixed_profiles, 
                                 size = nb_size, 
                                 n_cells = n_anchor_cells, 
                                 min_cosine = min_anchor_cosine, 
                                 min_scaled_llr = min_anchor_llr) 
  }
  # test anchors are valid:
  anchorcellnames = NULL
  if (!is.null(anchors) & (length(anchors) != nrow(counts))) {
    stop("anchors must have length equal to the number of cells (row) in counts")
  }
  names(anchors) <- rownames(counts)
  anchorcellnames <- names(anchors)[!is.na(anchors)]
  
  #### set up subsetting: ---------------------------------
  # get data for subsetting if not already provided
  # (e.g., if PCA is the choice, then point to existing PCA results, and run PCA if not available
  if (!is.null(sketchingdata)) {
    # check that it's correct:
    if (nrow(sketchingdata) != nrow(counts)) {
      warning("counts and sketchingdata have different numbers of row. Discarding sketchingdata.")
      sketchingdata <- NULL
    }
  }
  if (is.null(sketchingdata)) {
    sketchingdata <- prepDataForSketching(counts)
  }
  n_phase1 = min(n_phase1, nrow(counts))
  n_phase2 = min(n_phase2, nrow(counts))
  n_phase3 = min(n_phase3, nrow(counts))
  n_chooseclusternumber <- min(n_chooseclusternumber, nrow(counts))
  n_benchmark_cells = min(n_benchmark_cells, nrow(counts))
  
  
  ### choose cluster number: -----------------------------
  if (!is.null(init_clust)) {
    if (!is.null(n_clusts)) {
      message("init_clust was specified; this will overrule the n_clusts argument.")
    }
    n_clusts <- length(setdiff(unique(init_clust), colnames(fixed_profiles)))
  }
  if (is.null(n_clusts)) {
    n_clusts <- 1:12 + (is.null(fixed_profiles))
  }
  # get optimal number of clusters
  if (length(n_clusts) > 1) {
    
    message("Selecting optimal number of clusters from a range of ", min(n_clusts), " - ", max(n_clusts))
    
    chooseclusternumber_subset <- geoSketch(X = sketchingdata,
                                     N = n_benchmark_cells,
                                     alpha=0.1,
                                     max_iter=200,
                                     returnBins=FALSE,
                                     minCellsPerBin = 1,
                                     seed=NULL)
    chooseclusternumber_subset <- unique(c(chooseclusternumber_subset, anchorcellnames))
    
    n_clusts <- chooseClusterNumber(
      counts = counts[chooseclusternumber_subset, ], 
      neg = neg[chooseclusternumber_subset], 
      bg = bg[chooseclusternumber_subset], 
      anchors = anchors[chooseclusternumber_subset], 
      fixed_profiles = fixed_profiles,
      init_clust = NULL, 
      n_clusts = n_clusts,
      max_iters = 10,
      subset_size = length(chooseclusternumber_subset), 
      align_genes = TRUE, plotresults = FALSE, nb_size = nb_size)$best_clust_number 
  }
  
  #### phase 1: many random starts in small subsets -----------------------------
  
  if (!is.null(init_clust)) {
    message("init_clust was provided, so phase 1 - random starts in small subsets - will be skipped.")
    
    tempprofiles <- sapply(by(counts[!is.na(init_clust), ], init_clust[!is.na(init_clust)], colMeans), cbind)
    rownames(tempprofiles) <- colnames(counts)
    
  } else {
    message(paste0("phase 1: random starts in ", n_phase1, " cell subsets"))
    
    # get a list in which each element is the cell IDs to be used in a subset
    random_start_subsets <- list()
    for (i in 1:n_starts) {
      random_start_subsets[[i]] <- geoSketch(X = sketchingdata,
                                             N = n_phase1,
                                             alpha=0.1,
                                             max_iter=200,
                                             returnBins=FALSE,
                                             minCellsPerBin = 1,
                                             seed=NULL)
      random_start_subsets[[i]] <- unique(c(random_start_subsets[[i]], anchorcellnames))
      
      # convert IDs to row indices:
      random_start_subsets[[i]] <- match(random_start_subsets[[i]], rownames(counts))
      
    }
    
    # get a vector of cells IDs to be used in comparing the random starts:
    benchmarking_subset <- geoSketch(X = sketchingdata,
                                     N = n_benchmark_cells,
                                     alpha=0.1,
                                     max_iter=200,
                                     returnBins=FALSE,
                                     minCellsPerBin = 1,
                                     seed=NULL)
    # convert IDs to row indices:
    benchmarking_subset <- match(benchmarking_subset, rownames(counts))
    
    # run nbclust from each of the random subsets, and save the profiles:
    profiles_from_random_starts <- list()
    for (i in 1:n_starts) {
      
      tempinit <- NULL
      if (!is.null(fixed_profiles)) {
        tempinit <- choose_init_clust(counts = counts[random_start_subsets[[i]], ], 
                                      fixed_profiles = fixed_profiles, 
                                      bg = bg[random_start_subsets[[i]]], 
                                      size = nb_size, 
                                      n_clusts = n_clusts, 
                                      thresh = 0.9) 
        tempinit[intersect(names(tempinit), anchorcellnames)] <- anchors[intersect(names(tempinit), anchorcellnames)]
      } else {
        tempinit <- rep(letters[seq_len(n_clusts)], each = ceiling(length(random_start_subsets[[i]]) / n_clusts))[
          seq_along(random_start_subsets[[i]])]
      }

      
      profiles_from_random_starts[[i]] <- nbclust(
        counts = counts[random_start_subsets[[i]], ], 
        neg = neg[random_start_subsets[[i]]], 
        bg = bg[random_start_subsets[[i]]],
        anchors = anchors[random_start_subsets[[i]]], 
        init_profiles = NULL,
        init_clust = tempinit, 
        n_clusts = n_clusts,
        nb_size = nb_size,
        method = method, 
        pct_drop = pct_drop,
        min_prob_increase = min_prob_increase
      )$profiles
    }
    
    # find which profile matrix does best in the benchmarking subset:
    benchmarking_logliks <- c()
    for (i in 1:n_starts) {
      templogliks <- apply(profiles_from_random_starts[[i]], 2, function(ref) {
        lldist(x = ref,
               mat = counts[benchmarking_subset, ],
               bg = bg[benchmarking_subset],
               size = nb_size)
      })
      # take the sum of cells' best logliks:
      benchmarking_logliks[i] = sum(apply(templogliks, 1, max))
    }
    best_start <- which.max(benchmarking_logliks)
    tempprofiles <- profiles_from_random_starts[[best_start]]
    
    rm(profiles_from_random_starts)
    rm(templogliks)
  }
  
  #### phase 2: -----------------------------------------------------------------
  message(paste0("phase 2: refining best random start in a ", n_phase2, " cell subset"))
  phase2_sample <- geoSketch(X = sketchingdata,
                             N = n_phase2,
                             alpha=0.1,
                             max_iter=200,
                             returnBins=FALSE,
                             minCellsPerBin = 1,
                             seed=NULL)
  phase2_sample <- unique(c(phase2_sample, anchorcellnames))
  
  # convert IDs to row indices:
  phase2_sample <- match(phase2_sample, rownames(counts))
  
  # get initial cell type assignments:
  temp_init_clust <- NULL
  if (!is.null(init_clust)) {
    temp_init_clust <- init_clust[phase2_sample]
    tempprofiles <- NULL
  }
  
  # run nbclust, initialized with the cell type assignments derived from the previous phase's profiles
  clust2 <- nbclust(counts = counts[phase2_sample, ], 
                    neg = neg[phase2_sample], 
                    bg = bg[phase2_sample],
                    anchors = anchors[phase2_sample],
                    init_profiles = tempprofiles, 
                    init_clust = temp_init_clust, 
                    n_clusts = n_clusts,
                    nb_size = nb_size,
                    method = method, 
                    pct_drop = pct_drop,
                    min_prob_increase = min_prob_increase)
  tempprofiles <- clust2$profiles
 
  #### phase 3: -----------------------------------------------------------------
  message(paste0("phase 3: finalizing clusters in a ", n_phase3, " cell subset"))
  
  phase3_sample <- geoSketch(X = sketchingdata,
                             N = n_phase3,
                             alpha=0.1,
                             max_iter=200,
                             returnBins=FALSE,
                             minCellsPerBin = 1,
                             seed=NULL)
  phase3_sample <- unique(c(phase3_sample, anchorcellnames))
  
  # convert IDs to row indices:
  phase3_sample <- match(phase3_sample, rownames(counts))
  
  
  # run nbclust, initialized with the cell type assignments derived from the previous phase's profiles
  clust3 <- nbclust(counts = counts[phase3_sample, ], 
                    neg = neg[phase3_sample], 
                    bg = bg[phase3_sample],
                    anchors = anchors[phase3_sample],
                    init_profiles = tempprofiles, 
                    init_clust = NULL,  #temp_init_clust, 
                    n_clusts = n_clusts,
                    nb_size = nb_size,
                    method = method, 
                    pct_drop = pct_drop,
                    min_prob_increase = min_prob_increase)
  
  #### phase 4: -----------------------------------------------------------------
  message(paste0("phase 4: classifying all ", nrow(counts), " cells"))
  
  profiles <- clust3$profiles
  
  logliks <- apply(profiles, 2, function(ref) {
    lldist(x = ref,
           mat = counts,
           bg = bg,
           size = nb_size)
  })
  clust <- colnames(logliks)[apply(logliks, 1, which.max)]
  probs <- logliks2probs(logliks)
  out = list(clust = clust,
             probs = round(probs, 3),
             profiles = sweep(profiles, 2, colSums(profiles), "/") * nrow(profiles)) #,logliks = round(logliks, 3))
  return(out)
}