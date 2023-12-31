

#' Gene set analysis following differential expression with dream
#'
#' Perform gene set analysis on the result of differential expression using linear (mixed) modeling with \code{variancePartition::dream} by considering the correlation between gene expression traits.  This package is a slight modification of \code{limma::camera} to 1) be compatible with dream, and 2) allow identification of gene sets with log fold changes with mixed sign.
#'
#' @param fit result of differential expression with dream
#' @param coef coefficient to test using \code{topTable(fit, coef)}
#' @param index an index vector or a list of index vectors.  Can be any vector such that \code{fit[index,]} selects the rows corresponding to the test set.  The list can be made using \code{ids2indices}.
#' @param use.ranks do a rank-based test (\code{TRUE}) or a parametric test ('FALSE')?
#' @param allow.neg.cor should reduced variance inflation factors be allowed for negative correlations?
# @param squaredStats Test squared test statstics to identify gene sets with log fold change of mixed sign.
#' @param progressbar if TRUE, show progress bar
#' @param inter.gene.cor if NA, estimate correlation from data.  Otherwise, use specified value
#'
#' @details
#' \code{zenith} gives the same results as \code{camera(..., inter.gene.cor=NA)} which estimates the correlation with each gene set.  
#'
#' For differential expression with dream using linear (mixed) models see Hoffman and Roussos (2020).  For the original camera gene set test see Wu and Smyth (2012).
#' 
#' @references{
#'   \insertRef{hoffman2020dream}{zenith}
#' 
#'   \insertRef{wu2012camera}{zenith}
#' }
#'
#' @return
#' \itemize{
#'   \item \code{NGenes}: number of genes in this set
#'   \item \code{Correlation}: mean correlation between expression of genes in this set
#'   \item \code{delta}: difference in mean t-statistic for genes in this set compared to genes not in this set
#'   \item \code{se}: standard error of \code{delta}
#'   \item \code{p.less}: p-value for hypothesis test of \code{H0: delta < 0}
#'   \item \code{p.greater}: p-value for hypothesis test of \code{H0: delta > 0}
#'   \item \code{PValue}:  p-value for hypothesis test \code{H0: delta != 0}
#'   \item \code{Direction}: direction of effect based on sign(delta)
#'   \item \code{FDR}: false discovery rate based on Benjamini-Hochberg method in \code{p.adjust}
#' }
#'
#' @examples
#' library(variancePartition)
#' 
#' # simulate meta-data
#' info <- data.frame(Age=c(20, 31, 52, 35, 43, 45),Group=c(0,0,0,1,1,1))
#'
#' # simulate expression data
#' y <- matrix(rnorm(1000*6),1000,6)
#' rownames(y) = paste0("gene", 1:1000)
#' colnames(y) = rownames(info)
#' 
#' # First set of 20 genes are genuinely differentially expressed
#' index1 <- 1:20
#' y[index1,4:6] <- y[index1,4:6]+1
#' 
#' # Second set of 20 genes are not DE
#' index2 <- 21:40
#' 
#' # perform differential expression analysis with dream
#' fit = dream(y, ~ Age + Group, info)
#' fit = eBayes(fit)
#' 
#' # perform gene set analysis testing Age
#' res = zenith(fit, "Age", list(set1=index1,set2=index2) )
#' 
#' head(res)
#' 
#' @importFrom Rdpack reprompt
#' @import variancePartition stats utils methods progress 
#' @importFrom limma zscoreT
#'
#' @export
zenith <- function( fit, coef, index, use.ranks=FALSE, allow.neg.cor=FALSE, progressbar=TRUE, inter.gene.cor = 0.01){

  if( ! is(fit, 'MArrayLM') ){
    stop("fit must be of class MArrayLM from variancePartition::dream")
  }

  if( is.null(fit$residuals) ){
    stop("fit must be result of dream(..., computeResiduals=TRUE)")
  }

  if( length(coef) > 1 ){
    stop("zenith doesn't currently support multiple coefs")
  }

  if( any(!(coef %in% colnames(coef(fit)))) ){
    stop("coef must be in colnames(coef(fit))")
  }

  if( is.null(rownames(fit)) ){
    stop("rownames(fit) is NULL.  Each feature must have a unique name")
  }

  # Check index
  if(!is.list(index)) index <- list(set1=index)
  nsets <- length(index)
  if(nsets==0L) stop("index is empty")

  # Only keep residuals for genes present in the main part of fit
  # Currently fit[1:10,] subsets objects in a standard MArrayLM
  #   but residuals is not standard, so it is not subsetted
  fit$residuals = fit$residuals[rownames(fit),,drop=FALSE]
  
  if( fit$method == "ls" ){

    # extract test statistics
    tab = topTable(fit, coef, number=Inf, sort.by="none")
    Stat = tab$t

    if( ! use.ranks ){
      df = fit$df.total[1]
      Stat <- zscoreT( Stat, df=df, approx=TRUE, method="hill")
    }

    G = length( Stat )

    df.camera <- min(fit$df.residual[1], G - 2L)
  }else if( fit$method == "lmer"){
    # extract test statistics
    tab = topTable(fit, coef, number=Inf, sort.by="none")
    Stat = tab$z.std

    G = length( Stat )

    df.camera <- min(mean(fit$df.residual[,coef]), G - 2L)

  }else{
    stop("Model method must be either 'ls' or 'lmer'")
  }

  # get number of statistics
  ID = rownames(fit)  

  # Global statistics
  meanStat <- mean(Stat)
  varStat <- var(Stat)

  # setup progressbar
  if( progressbar ){
    # since time is quadratic in the size of the gene set
    total_work = sum(vapply(index, length, numeric(1))^2)

    pb <- progress_bar$new(
      format = " [:bar] :percent eta: :eta",
      clear = FALSE,
      total = total_work, width = 60)
  }
  cumulative_work = cumsum(vapply(index, length, numeric(1))^2)

  # tab <- matrix(0,nsets,5)
  # rownames(tab) <- names(index)
  # colnames(tab) <- c("NGenes","Correlation","Down","Up","TwoSided")
  tab = lapply(seq_len(nsets), function(i){    

    iset <- index[[i]]
    if(is.character(iset)) iset <- which(ID %in% iset)

    StatInSet <- Stat[iset]

    m <- length(StatInSet)
    m2 <- G-m

    # cumulative_work <<- cumulative_work + m^2

    # Compute correlation within geneset
    if( is.na(inter.gene.cor) ){
      res = corInGeneSet( fit, iset, squareCorr=FALSE)
      correlation = res$correlation
      vif = res$vif
    }else{
      correlation = inter.gene.cor
      vif = 1 + correlation * (m - 1) 
    }

    # test
    # correlation = 0
    # vif = 1

    if(use.ranks) {

      corr.use = correlation
      if( ! allow.neg.cor ) corr.use <- max(0,corr.use)

      res = .rankSumTestWithCorrelation(iset, statistics=Stat, correlation=corr.use, df=df.camera)

      df = data.frame(  NGenes      = m,
                        Correlation = correlation,
                        delta       = res$effect,
                        se          = res$se,
                        p.less      = res$less,
                        p.greater   = res$greater )
    }else{ 

      if( ! allow.neg.cor ) vif <- max(1,vif)

      meanStatInSet <- mean(StatInSet)
      delta <- G/m2*(meanStatInSet-meanStat)
      varStatPooled <- ( (G-1)*varStat - delta^2*m*m2/G ) / (G-2)
      delta.se = sqrt( varStatPooled * (vif/m + 1/m2) )
      two.sample.t = delta / delta.se

      # two.sample.t <- delta / sqrt( varStatPooled * (vif/m + 1/m2) )
      # tab[i,3] <- pt(two.sample.t,df=df.camera)
      # tab[i,4] <- pt(two.sample.t,df=df.camera,lower.tail=FALSE)

      df = data.frame(NGenes      = m,
                      Correlation = correlation,
                      delta       = delta,
                      se          = delta.se,
                      p.less      = pt(two.sample.t,df=df.camera),
                      p.greater   = pt(two.sample.t,df=df.camera,lower.tail=FALSE) )
    }

    if( progressbar & (i %% 100 == 0) ) pb$update( cumulative_work[i] / total_work )

    df 
  })
  tab = do.call(rbind, tab)
  rownames(tab) <- names(index)

  # p-value for two sided test
  # if( squaredStats ){
  #   tab$PValue = tab$p.greater
  #   tab$Direction = "Up"
  # }else{    
    tab$PValue = 2*pmin(tab$p.less, tab$p.greater)
    tab$Direction = ifelse(tab$p.less < tab$p.greater, "Down", "Up")
  # }

  tab$FDR = p.adjust(tab$PValue, "BH")

  if( progressbar ){
    if( ! pb$finished){
      pb$update( 1.0 )
      pb$terminate() 
    }
  }

  # tab[,5] <- 2*pmin(tab[,3],tab[,4])

  # # New column names (Jan 2013)
  # tab <- data.frame(tab,stringsAsFactors=FALSE)
  # Direction <- rep_len("Up",length.out=nsets)
  # Direction[tab$Down < tab$Up] <- "Down"
  # tab$Direction <- Direction
  # tab$PValue <- tab$TwoSided
  # tab$Down <- tab$Up <- tab$TwoSided <- NULL

  # # Add FDR
  # if(nsets>1) tab$FDR <- p.adjust(tab$PValue,method="BH")

  # Sort by p-value
  o <- order(tab$PValue)
  tab <- tab[o,]

  tab
}




#' Two Sample Wilcoxon-Mann-Whitney Rank Sum Test Allowing For Correlation
#' 
#' Same as \code{limma::.rankSumTestWithCorrelation}, but returns effect size.
#'
#' @param index any index vector such that \code{statistics[index]} contains the values of the statistic for the test group.
#' @param statistics numeric vector giving values of the test statistic.
#' @param correlation numeric scalar, average correlation between cases in the test group.  Cases in the second group are assumed independent of each other and other the first group.
#' @param df degrees of freedom which the correlation has been estimated.
#'
#' @details See \code{limma::.rankSumTestWithCorrelation}
#' @return data.frame storing results of hypothesis test
#'
.rankSumTestWithCorrelation = function (index, statistics, correlation = 0, df = Inf){
    n <- length(statistics)
    r <- rank(statistics)
    r1 <- r[index]
    n1 <- length(r1)
    n2 <- n - n1
    U <- n1 * n2 + n1 * (n1 + 1)/2 - sum(r1)
    mu <- n1 * n2/2
    if (correlation == 0 || n1 == 1) {
        sigma2 <- n1 * n2 * (n + 1)/12
    }
    else {
        sigma2 <- asin(1) * n1 * n2 + asin(0.5) * n1 * n2 * (n2 - 
            1) + asin(correlation/2) * n1 * (n1 - 1) * n2 * (n2 - 
            1) + asin((correlation + 1)/2) * n1 * (n1 - 1) * 
            n2
        sigma2 <- sigma2/2/pi
    }
    TIES <- (length(r) != length(unique(r)))
    if (TIES) {
        NTIES <- table(r)
        adjustment <- sum(NTIES * (NTIES + 1) * (NTIES - 1))/(n * 
            (n + 1) * (n - 1))
        sigma2 <- sigma2 * (1 - adjustment)
    }
    zlowertail <- (U + 0.5 - mu)/sqrt(sigma2)
    zuppertail <- (U - 0.5 - mu)/sqrt(sigma2)
    
    data.frame( effect  = -1*(U - mu), 
                se      = sqrt(sigma2),
                less    = pt(zuppertail, df = df, lower.tail = FALSE), 
                greater = pt(zlowertail, df = df))
}



















