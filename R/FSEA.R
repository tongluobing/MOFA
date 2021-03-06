##########################################################
## Functions to perform Feature Set Enrichment Analysis ##
##########################################################

#' @title Feature Set Enrichment Analysis
#' @name runEnrichmentAnalysis 
#' @description Method to perform feature set enrichment analysis on the feature loadings. \cr
#' The input is a data structure containing the feature set membership, usually relating biological pathways to genes. \cr
#' The output is a matrix of dimensions (number_gene_sets,number_factors) with p-values and other statistics.
#' @param object a \code{\link{MOFAmodel}} object.
#' @param view name of the view to perform enrichment on. Make sure that the feature names of the feature set file match the feature names in the MOFA model.
#' @param feature.sets data structure that holds feature set membership information.
#'  Must be either a binary membership matrix (rows are feature sets and columns are features) or
#'   a list of feature set indexes (see vignette for details).
#' @param factors character vector with the factor names to perform enrichment on. Alternatively, a numeric vector with the index
#'  of the factors. Default is all factors.
#' @param local.statistic the feature statistic used to quantify the association
#'  between each feature and each factor. Must be one of the following: 
#'  loading (the output from MOFA, default), 
#'  cor (the correlation coefficient between the factor and each feature), 
#'  z (a z-scored derived from the correlation coefficient).
#' @param global.statistic the feature set statisic computed from the feature statistics. Must be one of the following: 
#'  "mean.diff" (difference in means between the foreground set and the background set, default) or
#'  "rank.sum" (difference in rank sums between the foreground set and the background set).
#' @param statistical.test the statistical test used to compute the significance of the feature
#' set statistics under a competitive null hypothesis. Must be one of the following: 
#' "parametric" (very liberal, default), 
#' "cor.adj.parametric" (very conservative, adjusts for the inter-gene correlation), 
#' "permutation" (non-parametric, the recommended one if you can do sufficient number of permutations)
#' @param transformation optional transformation to apply to the feature-level statistics.
#' Must be one of the following "none" or "abs.value" (default).
#' @param min.size Minimum size of a feature set (default is 10).
#' @param nperm number of permutations. Only relevant if statistical.test is set to "permutation".
#'  Default is 1000.
#' @param cores number of cores to run the permutation analysis in parallel.
#'  Only relevant if statistical.test is set to "permutation". Default is 1.
#' @param p.adj.method Method to adjust p-values factor-wise for multiple testing.
#'  Can be any method in p.adjust.methods(). Default uses Benjamini-Hochberg procedure.
#' @param alpha FDR threshold to generate lists of significant pathways. Default is 0.1
#' @details 
#'  This function relates the factors to pre-defined biological pathways by performing a gene set enrichment analysis on the loadings.
#'  The general idea is to compute an activity score for every pathway in each factor based on its corresponding gene loadings.\cr
#'  This function is particularly useful when a factor is difficult to characterise based only on the genes with the highest loading. \cr
#'  We provide several pre-build gene set matrices in the MOFAdata package. See \code{https://github.com/bioFAM/MOFAdata} for details. \cr
#'  The function we implemented is based on the \code{\link[PCGSE]{pcgse}} function with some modifications. 
#'  Please read this paper https://www.ncbi.nlm.nih.gov/pmc/articles/PMC4543476 for details on the math.
#' @return a list with the following elements:
#' \item{feature.statistics}{feature statistics}
#' \item{set.statistics}{feature-set statistics}
#' \item{pval}{raw p-values}
#' \item{pval.adj}{adjusted p-values}
#' \item{sigPathways}{a list with enriched pathways}
#' @import foreach doParallel
#' @importFrom stats p.adjust p.adjust.methods
#' @export
#' @examples 
#' # Example on the CLL data
#' filepath <- system.file("extdata", "CLL_model.hdf5", package = "MOFAdata")
#' MOFA_CLL <- loadModel(filepath)
#' 
#' # perform Enrichment Analysis on mRNA data using pre-build Reactome gene sets
#' data("reactomeGS", package = "MOFAdata")
#' fsea.results <- runEnrichmentAnalysis(MOFA_CLL, view="mRNA", feature.sets=reactomeGS)
#' 
#' # heatmap of enriched pathways per factor at 1% FDR
#' plotEnrichmentHeatmap(fsea.results, alpha=0.01)
#' 
#' # plot number of enriched pathways per factor at 1% FDR
#' plotEnrichmentBars(fsea.results, alpha=0.01)
#' 
#' # plot top 10 enriched pathways on factor 5:
#' plotEnrichment(MOFA_CLL, fsea.results, factor=5,  max.pathways=10)

runEnrichmentAnalysis <- function(object, view,
                                  feature.sets, factors = "all",
                                  local.statistic = c("loading", "cor", "z"),
                                  global.statistic = c("mean.diff", "rank.sum"),
                                  statistical.test = c("parametric", "cor.adj.parametric", "permutation"),
                                  transformation = c("abs.value", "none"),
                                  min.size = 10, nperm = 1000, cores = 1,
                                  p.adj.method = "BH", alpha=0.1) {
  
  # Parse inputs
  local.statistic <- match.arg(local.statistic)
  transformation <- match.arg(transformation)
  global.statistic <- match.arg(global.statistic)
  statistical.test <- match.arg(statistical.test)

  # Define factors
  if (paste0(factors,collapse="") == "all") { 
    factors <- factorNames(object) 
  } else if (is.numeric(factors)) {
      factors <- factorNames(object)[factors]
  } else { 
    stopifnot(all(factors %in% factorNames(object))) 
  }
  
  # Collect observed data
  data <- object@TrainData[[view]]
  data <- t(data)
  
  # Collect relevant expectations
  W <- getWeights(object, view,factors)[[view]]
  Z <- getFactors(object,factors)
  
  # Check that there is no constant factor
  stopifnot( all(apply(Z,2,var, na.rm=TRUE)>0) )
    
  # turn feature.sets into binary membership matrices if provided as list
  if(is(feature.sets, "list")) {
    features <- Reduce(union, feature.sets)
    feature.sets <- vapply(names(feature.sets), function(nm) {
      tmp <- features %in% feature.sets[[nm]]
      names(tmp) <- features
      tmp
    }, logical(length(features)))
    feature.sets <-t(feature.sets)*1
  }

  if(!(is(feature.sets,"matrix") & all(feature.sets %in% c(0,1)))) 
    stop("feature.sets has to be a list or a binary matrix.")
  
  # Check if some features do not intersect between the feature sets and the observed data and remove them
  features <- intersect(colnames(data),colnames(feature.sets))
  if (length(features)== 0) stop("Feautre names in feature.sets do not match feature names in model.")
  data <- data[,features]
  W <- W[features,, drop=FALSE]
  feature.sets <- feature.sets[,features]
  
  # Filter feature sets with small number of features
  feature.sets <- feature.sets[rowSums(feature.sets)>=min.size,]
    
  # Print options
  message("Doing Feature Set Enrichment Analysis with the following options...")
  message(sprintf("View: %s", view))
  message(sprintf("Factors: %s", paste(as.character(factors),collapse=" ")))
  message(sprintf("Number of feature sets: %d", nrow(feature.sets)))
  message(sprintf("Local statistic: %s", local.statistic))
  message(sprintf("Transformation: %s", transformation))
  message(sprintf("Global statistic: %s", global.statistic))
  message(sprintf("Statistical test: %s", statistical.test))
  if (statistical.test=="permutation") {
    message(sprintf("Cores: %d", cores))
    message(sprintf("Number of permutations: %d", nperm))
  }
  
  # Non-parametric permutation test
  if (statistical.test == "permutation") {
    doParallel::registerDoParallel(cores=cores)

    null_dist_tmp <- foreach(rnd= seq_len(nperm)) %dopar% {
      perm <- sample(ncol(data))
      # Permute rows of the weight matrix to obtain a null distribution
      W_null <- W[perm,]
      rownames(W_null) <- rownames(W); colnames(W_null) <- colnames(W)
      # Permute columns of the data matrix correspondingly (only matters for cor.adjusted test)
      data_null <- data[,perm]
      rownames(data_null) <- rownames(data)
      
      # Compute null statistic
      s.null <- .pcgse(
        data=data_null, 
        prcomp.output = list(rotation=W_null, x=Z),
        pc.indexes = seq_along(factors), 
        feature.sets = feature.sets,
        feature.statistic = local.statistic,
        transformation = transformation,
        feature.set.statistic = global.statistic,
        feature.set.test = "parametric", nperm=NA)$statistic
      abs(s.null)
    }
    null_dist <- do.call("rbind", null_dist_tmp)
    colnames(null_dist) <- factors
    
    # Compute true statistics
    s.true <- .pcgse(
      data = data, 
      prcomp.output = list(rotation=W, x=Z),
      pc.indexes = seq_along(factors), 
      feature.sets = feature.sets,
      feature.statistic = local.statistic,
      transformation = transformation,
      feature.set.statistic = global.statistic,
      feature.set.test = "parametric", nperm=NA)$statistic
    colnames(s.true) <- factors
    rownames(s.true) <- rownames(feature.sets)
    
    # Calculate p-values based on fraction true statistic per factor and gene set is larger than permuted
    warning("A large number of permutations is required for the permutation approach!")
    xx <- array(unlist(null_dist_tmp),
                dim = c(nrow(null_dist_tmp[[1]]), ncol(null_dist_tmp[[1]]), length(null_dist_tmp)))
    ll <- lapply(seq_len(nperm), function(i) xx[,,i] > abs(s.true))
    values <- Reduce("+",ll)/nperm
    rownames(p.values) <- rownames(s.true); colnames(p.values) <- factors

  # Parametric test
  } else {
    results <- .pcgse(
      data = data,
      prcomp.output = list(rotation=W, x=Z),
      pc.indexes = seq_along(factors),
      feature.sets = feature.sets,
      feature.statistic = local.statistic,
      transformation = transformation,
      feature.set.statistic = global.statistic,
      feature.set.test = statistical.test, nperm=nperm)
  }
  
  # Parse results
  pathways <- rownames(feature.sets)
  colnames(results[["p.values"]]) <- colnames(results[["statistics"]]) <- colnames(results[["feature.statistics"]]) <- factors
  rownames(results[["p.values"]]) <- rownames(results[["statistics"]]) <- pathways
  rownames(results[["feature.statistics"]]) <- colnames(data)

  # adjust for multiple testing
  if(!p.adj.method %in%  p.adjust.methods) 
    stop("p.adj.method needs to be an element of p.adjust.methods")
  adj.p.values <- apply(results[["p.values"]], 2,function(lfw) p.adjust(lfw, method = p.adj.method))

  # obtain list of significant pathways
  sigPathways <- lapply(factors, function(j) rownames(adj.p.values)[adj.p.values[,j] <= alpha])
  
  # # Compute an activity score per pathway and sample
  # tmp <- matrix(nrow=nrow(data), ncol=length(pathways))
  # rownames(tmp) <- rownames(data); colnames(tmp) <- pathways
  # for (i in pathways) {
  #   features <- names(which(feature.sets[i,]==1))
  #   tmp[,i] <- apply(data[,features],1,mean,na.rm=T)
  # }
  
  results[["feature.statistics"]]
  # prepare output
  output <- list(
    pval = results[["p.values"]], 
    pval.adj = adj.p.values, 
    feature.statistics = results[["feature.statistics"]],
    set.statistics = results[["statistics"]],
    # pathway.activity = tmp,
    sigPathways = sigPathways
  )
  return(output)
}


########################
## Plotting functions ##
########################


#' @title Line plot of Feature Set Enrichment Analysis results
#' @name plotEnrichment
#' @description Method to plot Feature Set Enrichment Analyisis results for specific factors
#' @param object \code{\link{MOFAmodel}} object on which the Feature Set Enrichment Analyisis was performed
#' @param fsea.results output of \link{runEnrichmentAnalysis} function
#' @param factor Factor
#' @param alpha p.value threshold to filter out feature sets
#' @param max.pathways maximum number of enriched pathways to display
#' @param adjust use adjusted p-values?
#' @return a \code{ggplot2} object
#' @import ggplot2
#' @importFrom utils head
#' @export
#' @examples 
#' # Example on the CLL data
#' filepath <- system.file("extdata", "CLL_model.hdf5", package = "MOFAdata")
#' MOFA_CLL <- loadModel(filepath)
#' 
#' # perform Enrichment Analysis on mRNA data using pre-build Reactome gene sets
#' data("reactomeGS", package = "MOFAdata")
#' fsea.results <- runEnrichmentAnalysis(MOFA_CLL, view="mRNA", feature.sets=reactomeGS)
#' 
#' # Plot top 10 enriched pathwyas on factor 5:
#' plotEnrichment(MOFA_CLL, fsea.results, factor=5,  max.pathways=10)

plotEnrichment <- function(object, fsea.results, factor, alpha=0.1, max.pathways=25, adjust=TRUE) {
  
  # Sanity checks
  stopifnot(length(factor)==1) 
  if(is.numeric(factor)) factor <- factorNames(object)[factor]
  if(!factor %in% colnames(fsea.results$pval)) 
    stop(paste0("No feature set enrichment calculated for factor ", factor, ".\n
                Use runEnrichmentAnalysis first."))

  # get p-values
  if(adjust) p.values <- fsea.results$pval.adj else p.values <- fsea.results$pval

  # Get data  
  tmp <- as.data.frame(p.values[,factor, drop=FALSE])
  tmp$pathway <- rownames(tmp)
  colnames(tmp) <- c("pvalue")
  
  # Filter out pathways
  tmp <- tmp[tmp$pvalue<=alpha,,drop=FALSE]
  if(nrow(tmp)==0) {
    warning("No siginificant pathways at the specified alpha threshold. \n
            For an overview use plotEnrichmentHeatmap() or plotEnrichmentBars().")
    return()
  }
  
  # If there are too many pathways enriched, just keep the 'max_pathways' more significant
  if (nrow(tmp) > max.pathways)
    tmp <- head(tmp[order(tmp$pvalue),],n=max.pathways)
  
  # Convert pvalues to log scale
  tmp$logp <- -log10(tmp$pvalue)
  
  # Annotate significcant pathways
  # tmp$sig <- factor(tmp$pvalue<alpha)
  
  #order according to significance
  tmp$pathway <- factor(tmp$pathway <- rownames(tmp), levels = tmp$pathway[order(tmp$pvalue, decreasing = TRUE)])
  tmp$start <- 0

    p <- ggplot(tmp, aes_string(x="pathway", y="logp")) +
    # ggtitle(paste("Enriched sets in factor", factor)) +
    geom_point(size=5) +
    geom_hline(yintercept=-log10(alpha), linetype="longdash") +
    # scale_y_continuous(limits=c(0,7)) +
    scale_color_manual(values=c("black","red")) +
    geom_segment(aes_string(xend="pathway", yend="start")) +
    ylab("-log pvalue") +
    coord_flip() +
    theme(
      axis.text.y = element_text(size=rel(1.2), hjust=1, color='black'),
      axis.text.x = element_text(size=rel(1.2), vjust=0.5, color='black'),
      axis.title.y=element_blank(),
      legend.position='none',
      panel.background = element_blank()
    )
  
  return(p)
}

#' @title Heatmap of Feature Set Enrichment Analysis results
#' @name plotEnrichmentHeatmap
#' @description This method generates a heatmap with the adjusted p.values that
#'  result from the the feature set enrichment analysis. Rows are feature sets and columns are factors.
#' @param fsea.results output of \link{runEnrichmentAnalysis} function
#' @param alpha FDR threshold to filter out unsignificant feature sets which are
#'  not represented in the heatmap. Default is 0.05.
#' @param logScale boolean indicating whether to plot the log of the p.values.
#' @param ... extra arguments to be passed to \link{pheatmap} function
#' @return produces a heatmap
#' @import pheatmap
#' @importFrom grDevices colorRampPalette
#' @export
#' @examples 
#' # Example on the CLL data
#' filepath <- system.file("extdata", "CLL_model.hdf5", package = "MOFAdata")
#' MOFA_CLL <- loadModel(filepath)
#' 
#' # perform Enrichment Analysis on mRNA data using pre-build Reactome gene sets
#' data("reactomeGS", package = "MOFAdata")
#' fsea.results <- runEnrichmentAnalysis(MOFA_CLL, view="mRNA", feature.sets=reactomeGS)
#' 
#' # overview of enriched pathways per factor at an FDR of 1%
#' plotEnrichmentHeatmap(fsea.results, alpha=0.01)

plotEnrichmentHeatmap <- function(fsea.results, alpha = 0.05, logScale = TRUE, ...) {

  # get p-values
  p.values <- fsea.results$pval.adj
  p.values <- p.values[!apply(p.values, 1, function(x) sum(x>=alpha)) == ncol(p.values),, drop=FALSE]
  
  # Apply Log transform
  if (logScale) {
    p.values <- -log10(p.values)
    alpha <- -log10(alpha)
    col <- colorRampPalette(c("lightgrey", "red"))(n=10)
  } else {
    col <- colorRampPalette(c("red", "lightgrey"))(n=10)
  }
  
  # Generate heatmap
  # if (ncol(p.values)==1) cluster_cols <-FALSE
  pheatmap::pheatmap(p.values, color = col)
}


#' @title Barplot of Feature Set Enrichment Analysis results
#' @name plotEnrichmentBars
#' @description Method to generate a barplot with the number of enriched feature sets per factor
#' @param fsea.results output of \link{runEnrichmentAnalysis} function
#' @param alpha FDR threshold for calling enriched feature sets. Default is 0.05
#' @return a \link{ggplot2} object
#' @import ggplot2
#' @importFrom grDevices colorRampPalette
#' @export
#' @examples 
#' # Example on the CLL data
#' filepath <- system.file("extdata", "CLL_model.hdf5", package = "MOFAdata")
#' MOFA_CLL <- loadModel(filepath)
#' 
#' # perform Enrichment Analysis on mRNA data using pre-build Reactome gene sets
#' data("reactomeGS", package = "MOFAdata")
#' fsea.results <- runEnrichmentAnalysis(MOFA_CLL, view="mRNA", feature.sets=reactomeGS)
#' 
#' # Plot overview of number of enriched pathways per factor at an FDR of 1%
#' plotEnrichmentBars(fsea.results, alpha=0.01)

plotEnrichmentBars <- function(fsea.results, alpha = 0.05) {
  
  # Sanity checks
  if(all(fsea.results$pval.adj > alpha)) 
    stop(paste0("No enriched gene sets found on the considered factors at the FDR alpha of ", alpha,"."))
  
  # Get enriched pathways at FDR of alpha
  pathwayList <- lapply(colnames(fsea.results$pval.adj), function(f) {
    f <- fsea.results$pval.adj[,f]
    names(f)[f<=alpha]
  })
  names(pathwayList) <- colnames(fsea.results$pval.adj)
  pathwaysDF <- reshape2::melt(pathwayList, value.name="pathway")
  colnames(pathwaysDF) <- c("pathway", "factor")
  pathwaysDF <- dplyr::mutate(pathwaysDF, factor= factor(factor, levels = colnames(fsea.results$pval)))
  
  # Count enriched gene sets per pathway
  n_enriched <- table(pathwaysDF$factor)
  pathwaysSummary <- data.frame(
    n_enriched = as.numeric(n_enriched),
    factor = factor(names(n_enriched), levels = colnames(fsea.results$pval))
  )
  
  # Generate plot
  ggplot(pathwaysSummary, aes_string(x="factor", y="n_enriched")) +
    geom_bar(stat="identity") + coord_flip() + 
    ylab(paste0("Number of enriched gene sets at FDR ", alpha*100,"%")) +
    xlab("Factor") + 
    theme(
      legend.position = "bottom",
      axis.text.y = element_text(size=rel(1.2), hjust=1, color='black'),
      axis.text.x = element_text(size=rel(1.2), vjust=0.5, color='black'),
      panel.background = element_blank()
    )
}



##############################################
## From here downwards are internal methods ##
##############################################

# This is a modified version of the PCGSE module
.pcgse = function(data, prcomp.output, pc.indexes=1, feature.sets, feature.statistic="z", transformation="none", 
                  feature.set.statistic="mean.diff", feature.set.test="cor.adj.parametric", nperm=9999) {
  
  current.warn = getOption("warn")
  options(warn=-1)

  # Sanity checks
  if (is.null(feature.sets)) {
    stop("'feature.sets' must be specified!")
  }   
  options(warn=current.warn) 
  if (!(feature.statistic %in% c("loading", "cor", "z"))) {
    stop("feature.statistic must be 'loading', 'cor' or 'z'")
  }  
  if (!(transformation %in% c("none", "abs.value"))) {
    stop("transformation must be 'none' or 'abs.value'")
  }  
  if (!(feature.set.statistic %in% c("mean.diff", "rank.sum"))) {
    stop("feature.set.statistic must be 'mean.diff' or 'rank.sum'")
  }    
  if (!(feature.set.test %in% c("parametric", "cor.adj.parametric", "permutation"))) {
    stop("feature.set.test must be one of 'parametric', 'cor.adj.parametric', 'permutation'")
  }
  if (feature.set.test == "permutation" & feature.statistic == "loading") { 
    stop("feature.statistic cannot be set to 'loading' if feature.set.test is 'permutation'")
  }
  if (!is.matrix(feature.sets) & feature.set.test == "permutation") {
    stop("feature.sets must be specified as a binary membership matrix if
         feature.set.test is set to 'permutation'") 
  }  
  # if (feature.set.test == "parametric") {
    # warning("The 'parametric' test option ignores the correlation between feature-level
    #         test statistics and therefore has an inflated type I error rate.\n ",
    #         "This option should only be used for evaluation purposes.")
  # }  
  # if (feature.set.test == "permutation") {
    # warning("The 'permutation' test option can be extremely computationally expensive
    #         given the required modifications to the safe() function. ",
    #         "For most applications, it is recommended that feature.set.test
    #         is set to 'cor.adj.parametric'.")
  # }
  
  # Turn the feature set matrix into list form if feature.set.test is not "permutation"
  feature.set.indexes = feature.sets  
  if (is.matrix(feature.sets)) {
    feature.set.indexes = .createVarGroupList(var.groups=feature.sets)  
  }
  
  n = nrow(data)
  p = ncol(data)
  
  # Compute the feature statistics.
  feature.statistics = matrix(0, nrow=p, ncol=length(pc.indexes))
  for (i in seq_along(pc.indexes)) {
    pc.index = pc.indexes[i]
    feature.statistics[,i] = .computefeatureStatistics(
      data = data,
      prcomp.output = prcomp.output,
      pc.index = pc.index,
      feature.statistic = feature.statistic,
      transformation = transformation
    )
  }
  
  # Compute the feature-set statistics.
  if (feature.set.test == "parametric" | feature.set.test == "cor.adj.parametric") {
    if (feature.set.statistic == "mean.diff") {
      results = .pcgseViaTTest(
        data = data, 
        prcomp.output = prcomp.output,
        pc.indexes = pc.indexes,
        feature.set.indexes = feature.set.indexes,
        feature.statistics = feature.statistics,
        cor.adjustment = (feature.set.test == "cor.adj.parametric")
      )
    } else if (feature.set.statistic == "rank.sum") {
      results = .pcgseViaWMW(
        data = data, 
        prcomp.output = prcomp.output,
        pc.indexes = pc.indexes,
        feature.set.indexes = feature.set.indexes,
        feature.statistics = feature.statistics,
        cor.adjustment = (feature.set.test == "cor.adj.parametric")
      )
    }
  }
  
  # Add feature.statistics to the results
  results[["feature.statistics"]] <- feature.statistics
  
  return (results) 
}




# Turn the annotation matrix into a list of var group indexes for the valid sized var groups
.createVarGroupList = function(var.groups) {
  var.group.indexes = list()  
  for (i in seq_len(nrow(var.groups))) {
    member.indexes = which(var.groups[i,]==1)
    var.group.indexes[[i]] = member.indexes    
  }
  names(var.group.indexes) = rownames(var.groups)    
  return (var.group.indexes)
}

# Computes the feature-level statistics
.computefeatureStatistics = function(data, prcomp.output, pc.index, feature.statistic, transformation) {
  p = ncol(data)
  n = nrow(data)
  feature.statistics = rep(0, p)
  if (feature.statistic == "loading") {
    # get the PC loadings for the selected PCs
    feature.statistics = prcomp.output$rotation[,pc.index]
  } else {
    # compute the Pearson correlation between the selected PCs and the data
    feature.statistics = cor(data, prcomp.output$x[,pc.index], use = "complete.obs") 
    if (feature.statistic == "z") {
      # use Fisher's Z transformation to convert to Z-statisics
      feature.statistics = vapply(feature.statistics, function(x) {
        return (sqrt(n-3)*atanh(x))}, numeric(1))      
    }    
  }
  
  # Absolute value transformation of the feature-level statistics if requested
  if (transformation == "abs.value") {
    feature.statistics = vapply(feature.statistics, abs, numeric(1))
  }  
  
  return (feature.statistics)
}

# Compute enrichment via t-test
#' @importFrom stats pt
.pcgseViaTTest = function(data, prcomp.output, pc.indexes,
                          feature.set.indexes, feature.statistics, cor.adjustment) {
  
  num.feature.sets = length(feature.set.indexes)
  n= nrow(data)
  p.values = matrix(0, nrow=num.feature.sets, ncol=length(pc.indexes))  
  rownames(p.values) = names(feature.set.indexes)
  feature.set.statistics = matrix(TRUE, nrow=num.feature.sets, ncol=length(pc.indexes))    
  rownames(feature.set.statistics) = names(feature.set.indexes)    
  
  for (i in seq_len(num.feature.sets)) {
    indexes.for.feature.set = feature.set.indexes[[i]]
    m1 = length(indexes.for.feature.set)
    not.feature.set.indexes = which(!(seq_len(ncol(data)) %in% indexes.for.feature.set))
    m2 = length(not.feature.set.indexes)
    
    if (cor.adjustment) {      
      # compute sample correlation matrix for members of feature set
      cor.mat = cor(data[,indexes.for.feature.set], use = "complete.obs")
      # compute the mean pair-wise correlation 
      mean.cor = (sum(cor.mat) - m1)/(m1*(m1-1))    
      # compute the VIF, using CAMERA formula from Wu et al., based on Barry et al.
      vif = 1 + (m1 -1)*mean.cor
    }
    
    for (j in seq_along(pc.indexes)) {
      # get the feature-level statistics for this PC
      pc.feature.stats = feature.statistics[,j]
      # compute the mean difference of the feature-level statistics
      mean.diff = mean(pc.feature.stats[indexes.for.feature.set]) -
        mean(pc.feature.stats[not.feature.set.indexes])
      # compute the pooled standard deviation
      pooled.sd = sqrt(((m1-1)*var(pc.feature.stats[indexes.for.feature.set]) +
                          (m2-1)*var(pc.feature.stats[not.feature.set.indexes]))/(m1+m2-2))      
      # compute the t-statistic
      if (cor.adjustment) {
        t.stat = mean.diff/(pooled.sd*sqrt(vif/m1 + 1/m2))
        df = n-2
      } else {
        t.stat = mean.diff/(pooled.sd*sqrt(1/m1 + 1/m2))
        df = m1+m2-2
      }
      feature.set.statistics[i,j] = t.stat      
      # compute the p-value via a two-sided test
      lower.p = pt(t.stat, df=df, lower.tail=TRUE)
      upper.p = pt(t.stat, df=df, lower.tail=FALSE)        
      p.values[i,j] = 2*min(lower.p, upper.p)      
    }
  } 
  
  # Build the result list
  results = list()
  results$p.values = p.values
  results$statistics = feature.set.statistics  
  
  return (results)
}

# Compute enrichment via Wilcoxon Mann Whitney 
#' @importFrom stats wilcox.test pnorm
.pcgseViaWMW = function(data, prcomp.output, pc.indexes,
                        feature.set.indexes, feature.statistics, cor.adjustment) {
  
  num.feature.sets = length(feature.set.indexes)
  n= nrow(data)
  p.values = matrix(0, nrow=num.feature.sets, ncol=length(pc.indexes))  
  rownames(p.values) = names(feature.set.indexes)
  feature.set.statistics = matrix(TRUE, nrow=num.feature.sets, ncol=length(pc.indexes))    
  rownames(feature.set.statistics) = names(feature.set.indexes)    
  
  for (i in seq_len(num.feature.sets)) {
    indexes.for.feature.set = feature.set.indexes[[i]]
    m1 = length(indexes.for.feature.set)
    not.feature.set.indexes = which(!(seq_len(ncol(data)) %in% indexes.for.feature.set))
    m2 = length(not.feature.set.indexes)
    
    if (cor.adjustment) {            
      # compute sample correlation matrix for members of feature set
      cor.mat = cor(data[,indexes.for.feature.set])
      # compute the mean pair-wise correlation 
      mean.cor = (sum(cor.mat) - m1)/(m1*(m1-1))    
    }
    
    for (j in seq_along(pc.indexes)) {
      # get the feature-level statistics for this PC
      pc.feature.stats = feature.statistics[,j]
      # compute the rank sum statistic feature-level statistics
      wilcox.results = wilcox.test(x=pc.feature.stats[indexes.for.feature.set],
                                   y=pc.feature.stats[not.feature.set.indexes],
                                   alternative="two.sided", exact=FALSE, correct=FALSE)
      rank.sum = wilcox.results$statistic                
      if (cor.adjustment) {
        # Using correlation-adjusted formula from Wu et al.
        var.rank.sum = ((m1*m2)/(2*pi))*
          (asin(1) + (m2 - 1)*asin(.5) + (m1-1)*(m2-1)*asin(mean.cor/2) +(m1-1)*asin((mean.cor+1)/2))
      } else {        
        var.rank.sum = m1*m2*(m1+m2+1)/12
      }
      z.stat = (rank.sum - (m1*m2)/2)/sqrt(var.rank.sum)
      feature.set.statistics[i,j] = z.stat
      
      # compute the p-value via a two-sided z-test
      lower.p = pnorm(z.stat, lower.tail=TRUE)
      upper.p = pnorm(z.stat, lower.tail=FALSE)        
      p.values[i,j] = 2*min(lower.p, upper.p)
    }
  } 
  
  # Build the result list
  results = list()
  results$p.values = p.values
  results$statistics = feature.set.statistics  
  
  return (results)
}
