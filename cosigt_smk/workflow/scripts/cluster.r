#!/usr/bin/env Rscript 
library(data.table)
library(reshape2)
library(rjson)
library(dbscan)
library(cluster)

setDTthreads(1)

args <- commandArgs(trailingOnly = TRUE)
input_file <- args[1]
output_file <- args[2]
similarity_threshold<-args[3]
region_similarity<-round(as.numeric(args[4]),2)

df <- fread(input_file,header=T)

#dist-matrix
regularMatrix <- acast(df, group.a ~ group.b, value.var = "estimated.difference.rate")
maxD<-max(regularMatrix[!is.na(regularMatrix)])
regularMatrix[is.na(regularMatrix)]<-Inf
normRegularMatrix<-regularMatrix/maxD
distanceMatrix <- as.dist(normRegularMatrix)

if (similarity_threshold != "automatic") { #not used at the moment
  similarity_threshold<-as.numeric(similarity_threshold)
  optimal_eps<-1-similarity_threshold
} else {
  #guess the optimal threshold
  #we test many eps values, in the range to 0.00 to 0.30 dissimilarity (0% to 30%), increasing by 0.01 (1%) at each iteration.
  #with 0, each haplotype clusters independently, then they start clustering together.
  #we stop when allowing for larger dissimilarity does not influence much the number of clusters - diff is < 1
  #for regions that share a lot of similarity (>90%, as defined by the sum of lengths of shared nodes), we ensure that no more than n.hap/10 clusters are generated
  optimal_eps <- 0
  res <- dbscan(distanceMatrix, eps=optimal_eps, minPts=1)$cluster
  pclust <- length(table(res))
    
  for (eps in seq(from=0.01, to=0.30, by=0.01)) {
    res <- dbscan(distanceMatrix, eps=eps, minPts=1)$cluster
    cclust <- length(table(res))
    #stability criterion
    if (abs(pclust - cclust) <= 1) {  # Max 1 cluster difference 
      if ((region_similarity >= 0.9 && cclust <= round(length(unique(df$group.a))/10)) || 
          region_similarity < 0.9) {
        optimal_eps <- eps
        break
      }
    }
    pclust <- cclust
  }
}

res <- dbscan(distanceMatrix, eps=optimal_eps, minPts = 1)$cluster
names(res)<-labels(distanceMatrix)

#results
res.list <- lapply(split(res, names(res)), unname)
named_res <- lapply(res, function(x, prefix) paste0(prefix, x), prefix = "HaploGroup")
jout <- toJSON(named_res)

#write json
write(jout, output_file)

#create reversed data
reversed_data <- list()
for (key in names(named_res)) {
    value <- named_res[[key]]
    if (!is.null(reversed_data[[value]])) {
        reversed_data[[value]] <- c(reversed_data[[value]], key)
    } else {
        reversed_data[[value]] <- key
    }
}

#create haplotype table
haplotable <- data.frame(
    haplotype.name = unlist(reversed_data),
    haplotype.group = rep(names(reversed_data), lengths(reversed_data))
)
rownames(haplotable) <- NULL

#write-out
tsv_output <- gsub(".json", ".tsv", output_file)
fwrite(haplotable, tsv_output, row.names = FALSE, col.names = TRUE, sep = "\t")

k <- as.numeric(tail(sort(res), 1))
#write distances?
cluster_dist_norm <- matrix(0, nrow = k, ncol = k)
rownames(cluster_dist_norm) <- paste0("HaploGroup", 1:k)
colnames(cluster_dist_norm) <- paste0("HaploGroup", 1:k)
cluster_dist<-cluster_dist_norm

#what if we have a single haplogroup?
#can happen if the haplotypes don't look good
if (k == 1) {
  cluster_dist_norm[1,1] <- 0
  cluster_dist[1,1] <- 0
} else {
  for(i in 1:(k-1)) {
    for(j in (i+1):k) {
      # Get indices for each cluster
      cluster_i <- which(res == i)
      cluster_j <- which(res == j)  
      # Calculate mean distance between clusters
      distances <- normRegularMatrix[cluster_i, cluster_j, drop = FALSE]
      mean_dist <- mean(distances)
      # Store distances symmetrically
      cluster_dist_norm[i,j] <- mean_dist
      cluster_dist_norm[j,i] <- mean_dist
      distances <- regularMatrix[cluster_i, cluster_j, drop = FALSE]
      mean_dist <- mean(distances)
      cluster_dist[i,j] <- mean_dist
      cluster_dist[j,i] <- mean_dist
    }
  }
}

#also output clustering metrics
metrics_output <- gsub(".json", ".metrics.tsv", output_file)
metrics <- data.frame(
  eps = optimal_eps,
  num_clusters = k
)
fwrite(metrics, metrics_output, row.names=FALSE, col.names=TRUE, sep="\t")

distance_output <- gsub(".json", ".hapdist.norm.tsv", output_file)
fwrite(data.frame(h.group=row.names(cluster_dist_norm),cluster_dist_norm), distance_output, row.names = FALSE, col.names = TRUE, sep = "\t")
distance_output <- gsub(".json", ".hapdist.tsv", output_file)
fwrite(data.frame(h.group=row.names(cluster_dist),cluster_dist), distance_output, row.names = FALSE, col.names = TRUE, sep = "\t")
