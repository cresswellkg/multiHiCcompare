#' Perform exact test based difference detection on a Hi-C experiment
#' 
#' @param hicexp A hicexp object.
#' @param parallel Logical, should parallel processing be used?
#' @param p.method Charact string to be input into p.adjust()
#'    as the method for multiple testing correction. Defaults to "fdr".
#' @param max.pool The proportion of unit distances after
#'     which all further distances will be pooled. Distances
#'     before this value will be progressively pooled and
#'     any distances after this value will be combined
#'     into a single pool. Defaults to 0.7. Warning: do
#'     not adjust this value from the default unless you
#'     are getting errors related to the lfproc function
#'     or due to sparsity in fastlo normalization. If these
#'     errors occur it is due to either sparsity or low 
#'     variance and max.pool will need to be lowered; 
#'     typically to 0.5 or 0.6. 
#'     
#' @details This function performs the edgeR exact test on a per distance
#'     basis for Hi-C data. It tests for differences between two groups
#'     when the groups are the only variable of interest. This is
#'     an application of the negative binomial exact test proposed
#'     by Robinson and Smyth (2008) for a difference in mean between
#'     the groups. These exact tests are applied to the Hi-C data
#'     on a distance group basis using "progressive pooling" of 
#'     distances. 
#' @return A hicexp object with the comparison slot filled.
#'
#' @export
#' @import edgeR
#' @examples 
#' \dontrun{
#' data("hicexp_diff")
#' hicexp_diff <- hic_exactTest(hicexp_diff)}
#' 

hic_exactTest <- function(hicexp, parallel = FALSE, p.method = "fdr", max.pool = 0.7) {
  # check to make sure hicexp is normalized
  if (!normalized(hicexp)) {
    warning("You should normalize the data before entering it into hic_glm")
  }
  # check to make sure there are only 2 groups
  if ( length(unique(meta(hicexp)$group)) != 2) {
    stop("If you are making a comparison where the number of groups is not 2 
         or you have covariates use hic_glm() instead.")
  }
  # First need to split up hic_table by chr and then by distance
  # split up data by chr
  table_list <- split(hic_table(hicexp), hic_table(hicexp)$chr)
  # for each chr create list of distance matrices
  table_list <- lapply(table_list, .get_dist_tables, max.pool = max.pool)
  # combine list of lists into single list of tables
  table_list <- do.call(c, table_list)
  # input each of the chr-distance tables into a DGElist object for edgeR
  dge_list <- lapply(table_list, .hictable2DGEList, covariates = meta(hicexp))
  # estimate dispersion for data
  # check number of samples per group
  if ( length(meta(hicexp)$group) == 2) { # IF no replicates use edgeR's recommended method to estimate dispersion
    dge_list <- smartApply(parallel, dge_list, edgeR::estimateGLMCommonDisp,
                                                          method="deviance", robust=TRUE, 
                                                          subset=NULL)
  } else { # If replicates for condition then use standard way for estimating dispersion
    dge_list <- smartApply(parallel, dge_list, edgeR::estimateDisp, 
                           design=model.matrix(~meta(hicexp)$group))

  }
  
  # perform exact test when the only factor is group
  et <- lapply(dge_list, edgeR::exactTest)
  
  # reformat results back into hicexp object
  comparison <- mapply(.et_reformat, et, table_list, SIMPLIFY = FALSE, 
                       MoreArgs = list(p.method = p.method))
  comparison <- data.table::rbindlist(comparison)
  # sort comparison table
  comparison <- comparison[order(chr, region1, region2),]
  slot(hicexp, "comparison") <- data.table::as.data.table(comparison)
  
  # return results
  return(hicexp)
}




#' Function to perform GLM differential analysis on Hi-C experiment
#' 
#' @param hicexp A hicexp object,
#' @param design A design matrix for the GLM.
#' @param contrast Numeric vector or matrix specifying one or more 
#'     contrasts of the linear model coefficients to be tested 
#'     equal to zero.
#' @param coef integer or character index vector indicating which 
#'     coefficients of the linear model are to be tested equal to zero. 
#' @param method The test method to be performed. Should be one of
#'    "QLFTest", "LRTest", or "Treat".
#' @param M The log2 fold change value for a TREAT analysis.
#' @param p.method p-value adjustment method to be used. Defaults
#'     to "fdr". See ?p.adjust for other adjustment options.
#' @param parallel Logical, Should parallel processing be used?
#' @param max.pool The proportion of unit distances after
#'     which all further distances will be pooled. Distances
#'     before this value will be progressively pooled and
#'     any distances after this value will be combined
#'     into a single pool. Defaults to 0.7. Warning: do
#'     not adjust this value from the default unless you
#'     are getting errors related to the lfproc function
#'     or due to sparsity in fastlo normalization. If these
#'     errors occur it is due to either sparsity or low 
#'     variance and max.pool will need to be lowered; 
#'     typically to 0.5 or 0.6. 
#'     
#' @details This function performs the specified edgeR GLM based test
#'     on a per distance basis on the Hi-C data. Distances groups
#'     are pooled using "progressive pooling". There are 3 options
#'     for the type of GLM based test to be used which is specified
#'     with the method option. \cr
#'     \code{QLFTest} will use edgeR's glmQLFit and glmQLFTest functions which
#'     makes use of quasi-likelihood methods described in Lund
#'     et al (2012). \cr
#'     \code{LRTest} uses edgeR's glmFit and glmLRT functions which uses
#'     a interaction-wise negative binomial general linear model.
#'     This method uses a likelihood ratio test for the coefficients
#'     specified in the model. \cr
#'     \code{Treat} uses edgeR's glmTreat function which performs a test
#'     for differential expression with a minimum required fold-change
#'     threshold imposed. It tests whether the absolute value of the 
#'     log2 fold change is greater than the value specified as the \code{M}
#'     option.
#'      
#' @return A hicexp object with a filled in comparison slot.
#' @import edgeR
#' @importFrom data.table rbindlist
#' @export
#' @examples 
#' \dontrun{
#' data("hicexp_diff")
#' d <- model.matrix(~factor(meta(hicexp_diff)$group) + factor(c(1,2,1,2)))
#' hicexp_diff <- hic_glm(hicexp_diff, design = d, coef = 2)}
#' 
hic_glm <- function(hicexp, design, contrast = NA, coef = NA, 
                    method = "QLFTest", M = 1, p.method = "fdr", 
                    parallel = FALSE, max.pool = 0.7) {
  # match method
  method <- match.arg(method, c("LRTest", "QLFTest", "Treat"), 
                      several.ok = FALSE)
  # check to make sure hicexp is normalized
  if (!normalized(hicexp)) {
    warning("You should normalize the data before entering it into hic_glm")
  }
  # contrast & coef input
  if ( (is.na(contrast[1]) & is.na(coef[1])) | 
       (!is.na(contrast[1]) & !is.na(coef[1])) ) {
    stop("You must enter a value for contrast or a coef, but not both")
  }
  
  # First need to split up hic_table by chr and then by distance
  # split up data by chr
  table_list <- split(hic_table(hicexp), hic_table(hicexp)$chr)
  # for each chr create list of distance matrices
  table_list <- lapply(table_list, .get_dist_tables, max.pool = max.pool)
  # combine list of lists into single list of tables
  table_list <- do.call(c, table_list)
  # input each of the chr-distance tables into a DGElist object for edgeR
  dge_list <- lapply(table_list, .hictable2DGEList, 
                     covariates = meta(hicexp))
  # estimate dispersion for data
  dge_list <- smartApply(parallel, dge_list, edgeR::estimateDisp, 
                         design = design)

  
  # fit the GLM
  fit <- smartApply(parallel, dge_list, edgeR::glmQLFit, design = design)

  
  ## Perform test based on method and contrast/coef specified 
  
    # QL F-test test
    if (method == "QLFTest") {
      if (is.na(coef)) {
        result <- smartApply(parallel, fit, edgeR::glmQLFTest,
                                         contrast = contrast)
      } else {
        result <- smartApply(parallel, fit, edgeR::glmQLFTest,
                                         coef = coef)
      }
    }
    # Likelihood Ratio Test
    if (method == "LRTest") {
      if (is.na(coef)) {
        result <- smartApply(parallel, fit, edgeR::glmLRT,
                                         contrast = contrast)
      } else {
        result <- smartApply(parallel, fit, edgeR::glmLRT,
                                         coef = coef)
      }
    }
    # TREAT Analysis based on a minimum log2 fold change specified as M
    if (method == "Treat") {
      if (is.na(coef)) {
        result <- smartApply(parallel, fit, edgeR::glmTreat,
                                         contrast = contrast, lfc = M)
      } else {
        result <- smartApply(parallel, fit, edgeR::glmTreat,
                                         coef = coef, lfc = M)
      }
    }
  
  # format results for differentially interacting regions
  result <- mapply(.glm_reformat, result, table_list,
                   MoreArgs = list(p.method = p.method), SIMPLIFY = FALSE)
  result <- data.table::rbindlist(result)
  # sort comparison table
  result <- result[order(chr, region1, region2),]
  slot(hicexp, "comparison") <- data.table::as.data.table(result)
  
  
  return(hicexp)
}




## Background functions

# Reformat exact test results and adjust p-values
## !!! current p-value adjustment is taking place on per distance basis
.et_reformat <- function(et_result, hic_table, p.method) {
  # create table of location info and p-value results
  result <- cbind(hic_table[, c("chr", "region1", "region2", "D"), with = FALSE], et_result$table)
  colnames(result)[7] <-"p.value"
  # adjust p-values
  result$p.adj <- p.adjust(result$p.value, method = p.method)
  # convert logFC from natural log to log2
  result$logFC <- log2(exp(result$logFC))
  return(result)
}


# reformat results of GLM
.glm_reformat <- function(result, hic_table, p.method) {
  # create table of location info and p-value results
  result <- cbind(hic_table[, c("chr", "region1", "region2", "D"), with = FALSE], result$table)
  colnames(result)[ncol(result)] <-"p.value"
  # adjust p-values
  result$p.adj <- p.adjust(result$p.value, method = p.method)
  # convert logFC from natural log to log2
  result$logFC <- log2(exp(result$logFC))
  return(result)
}



# function to convert hic_table to a DGEList object
.hictable2DGEList <- function(hic_table, covariates) {
  # convert IFs into a matrix
  IFs <- as.matrix(hic_table[, -c("chr", "region1", "region2", "D"), with = FALSE])
  # create DGEList 
  dge <- DGEList(counts = IFs, samples = covariates)
  return(dge)
}



