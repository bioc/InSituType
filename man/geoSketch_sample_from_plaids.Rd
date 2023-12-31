% Generated by roxygen2: do not edit by hand
% Please edit documentation in R/geoSketch.R
\name{geoSketch_sample_from_plaids}
\alias{geoSketch_sample_from_plaids}
\title{Subsample from plaids}
\usage{
geoSketch_sample_from_plaids(Plaid, N)
}
\arguments{
\item{Plaid}{Vector of cells' plaid IDs}

\item{N}{desired sample size}
}
\value{
Plaid, a named vector of binIDs where names correspond to cellIDs

sampledCells, a vector of cellIDs sampled using the geometric sketching method
}
\description{
Sample cells, trying to give each plaid equal representation
}
\examples{
data("mini_nsclc")
plaids <- geoSketch_get_plaid(mini_nsclc$counts, 100)
geoSketch_sample_from_plaids(plaids, 5)
}
