# File: preprocess.R
# Supports: code/kmer-analysis.R
# Generates fastaAll and metaDataAll from raw GISAID data

# INSTALL AND LOAD PACKAGES ################################

library(datasets)  # Load base packages manually

# Installs pacman ("package manager") if needed
if (!require("pacman"))
  install.packages("pacman", repos = "https://cran.case.edu")
library(pacman)

# Use pacman to load add-on packages as desired
# First call are standard packages for the project
pacman::p_load(pacman, dplyr, GGally, ggplot2, ggthemes, 
               ggvis, httr, lubridate, plotly, psych,
               rio, rmarkdown, shiny,
               stringr, tidyr, tidyverse)
# Second call are file-specific packages
pacman::p_load(ape, kmer, readr, lubridate, stringr, validate, gsubfn, seqinr)

# Note: gsubfn is used to destructure more than one return value

# LOAD SOURCES ################################
source('code/R/helper.R')

# LOAD DATA ################################################
# Assumption: tar filename format is country-variant-etc.
# Extract GISAID tars to data/GISAID/datasets/country-variant
# If data/GISAID/datasets already exist, do not do this routine
# Note: Each tar = {tsv, fasta}

# Note: All paths are relative to project root.

# preprocess() below defaults to seed = 10 or stratSize = 100 if not provided.
# This function performs:
# 1. Data parsing and augmentation
# 2. Stratified random sampling
# 3. Sanitation
preprocess <- function(dataPath, extractPath, seed = 10, stratSize = 100,
                       country_exposure = 'Philippines',
                       write_fastacsv = FALSE, stamp) {
  # dataPath is GISAID data path
  # extractPath is GISAID data extraction path after getting untarred
  if (dir.exists(extractPath)) {
    print("GISAID data already extracted from tar archives.")
  } else {
    tars <- list.files(dataPath, pattern = '.+\\.tar')
    for (fileName in tars) {
      subdir <- str_match(fileName, pattern='[^-]+-[^-]+')
      print(paste("Extracting to:", subdir))
      untar(paste(dataPath, fileName, sep='/'),
            exdir = paste(extractPath, subdir, sep='/'),
            verbose = FALSE)
    }
  }
  
  # Merge all extracted fasta and tsv files
  # fasta contains sequence, while tsv contains meta
  omicron_sub = c('ba275', 'xbb', 'xbb_1.5', 'xbb_1.16', 'xbb1.91')
  
  fastas <- list.files(extractPath, recursive = TRUE, pattern = '.+\\.fasta')
  tsvs <- list.files(extractPath, recursive = TRUE, pattern = '.+\\.tsv')
  nfiles <- length(fastas)
  
  fastaAll <- data.frame()
  metaDataAll <- data.frame()
  
  # warnings suppressed for data parsing, but handled cleanly so don't worry
  suppressWarnings({
    for (i in 1:nfiles) {
      fastaPath <- paste(extractPath, fastas[i], sep='/')
      tsvPath <- paste(extractPath, tsvs[i], sep='/')
      variant <- str_match(fastaPath, pattern = '(?<=-).*(?=\\/)')
      if (variant %vin% omicron_sub) {
        variant <- 'Omicron Sub'
      }
      variant <- str_to_title(variant)
      print(paste("Reading", fastaPath))
      print(paste("Reading", tsvPath))
      
      # Parse then merge fasta file with accumulator
      # Optimization: If write_fasta == TRUE, then use seqinr, else use ape.
      if (write_fastacsv) {
        fasta <- seqinr::read.fasta(fastaPath, forceDNAtolower = FALSE)
      } else {
        fasta <- ape::read.FASTA(fastaPath)
      }
      fastaAll <- c(fastaAll, fasta)
      
      # Parse then merge metaData file with accumulator
      # Defer sanitation after random sampling so fasta and metaData maintains 1:1
      metaData <- as.data.frame(read_tsv(tsvPath,
                                         col_select = c(1,5,10,11,12,16,17,19)))
      # Not removing raw date as I believe it is useful for sorting or can be
      # parsed on an as needed basis. Dropped year, month, day: just extract
      # them from the date using lubridate:{year,month,day}(date).
      metaData <- metaData %>%
        dplyr::mutate(variant = as.character(variant))
      
      # NAs introduced by coercion will be dropped later because dropping
      # metadata rows must be consistent with dropping fasta entries for
      # the reason that efficient df columns with lists are not well-supported
      # in R. Tibbles on the other hand reduce efficiency and compatibility.
      # Also, using tibbles add another need to extract the fasta from the tibble
      # for later use (and for writeback), and rowwise operations in tibbles
      # are said to be slow.
      metaData$age <- as.integer(metaData$age)
      metaData$sex <- as.character(metaData$sex)
      
      metaDataAll <- bind_rows(metaDataAll, metaData)
    }
  })

  rm(fasta)
  rm(metaData)
  
  # Addon: Filter by country_exposure
  drop_idxs <- which(metaDataAll$country != country_exposure)
  fastaAll <- fastaAll[is.na(pmatch(1:length(fastaAll), drop_idxs))]
  metaDataAll <- metaDataAll[is.na(pmatch(1:nrow(metaDataAll), drop_idxs)),]
  
  rm(drop_idxs)
  
  # At this point, fastaAll and metaDataAll contains the needed data
  # Now do stratified random sampling of <sampleSize> samples
  # seed = 10         # seed for random number generator
  # stratSize = 100  # sample size per stratum
  set.seed(seed)
  
  # Note: append row names to column for fasta sampling
  # Drop rowname col before exporting!
  metaGrouped <- metaDataAll %>%
    dplyr::group_by(variant) %>%
    tibble::rownames_to_column()
  
  # Do not preserve grouping structure (below only) to avoid NULL groups
  droppedVariants <- filter(metaGrouped, n() < stratSize)
  metaGrouped <- filter(metaGrouped, n() >= stratSize) %>%
    sample_n(stratSize)
  metaDataAll <- bind_rows(metaGrouped, droppedVariants)
  
  rm(droppedVariants)
  rm(metaGrouped)
  
  set.seed(NULL)  # reset seed (rest of code is true random)
  
  idxs <- as.integer(metaDataAll$rowname)
  fastaAll <- fastaAll[idxs]
  
  # drop rowname column
  metaDataAll = subset(metaDataAll, select = -c(rowname) )  
  
  # Drop rows with NA values and type mismatches
  # For dropping, get the idxs of the dropped rows and also drop them in fastaAll
  drop_idxs1 <- which(is.na(metaDataAll), arr.ind=TRUE)[,1]
  drop_idxs2 <- c(which(is.numeric(metaDataAll$sex)),
                  which(!(metaDataAll$sex %vin% list("Male", "Female"))))
  drop_idxs3 <- which(lengths(fastaAll) == 0)
  drop_idxs <- unique(c(drop_idxs1, drop_idxs2, drop_idxs3))
  
  # Dropping below is analogoues to select inverse
  # pmatch creates matches, val for match and NA for no match
  # We only take those without matches, i.e. those that won't be
  # dropped.
  fastaAll <- fastaAll[is.na(pmatch(1:length(fastaAll), drop_idxs))]
  metaDataAll <- metaDataAll[is.na(pmatch(1:nrow(metaDataAll), drop_idxs)),]
  
  # At this point, data has been stratified and randomly sampled
  
  # Addon: Fix regions
  metaDataAll$division_exposure <- case_match(
    metaDataAll$division_exposure,
    'Bicol' ~ 'Bicol Region',
    'Calabarzon' ~ 'CALABARZON',
    'Mimaropa' ~ 'MIMAROPA',
    'National Capital Region' ~ 'NCR',
    'Cordillera Administrative Region' ~ 'CAR',
    'Ilocos' ~ 'Ilocos Region',
    'Davao' ~ 'Davao Region',
    'Bangsamoro Autonomous Region in Muslim Mindanao' ~ 'BARMM',
    'Autonomous Region In Muslim Mindanao(ARMM)' ~ 'BARMM',
    'Soccsksargen' ~ 'SOCCSKARGEN',
    'Zamboanga' ~ 'Zamboanga Peninsula',
    'Region IV-A' ~ 'CALABARZON',
    'Region XII (Soccsksargen)' ~ 'SOCCSKARGEN',
    'Region X (Northern Mindanao)' ~ 'Northern Mindanao',
    .default = metaDataAll$division_exposure
  )
  
  # Addon: Add age_group, adjacent to age column
  # Age group reference: https://www.statcan.gc.ca/en/concepts/definitions/age2
  metaDataAll <- metaDataAll %>%
    dplyr::mutate(age_group = cut(age, breaks=c(0,14,24,64,500),
                                  include.lowest=T,
                                  labels=c('0-14', '15-24', '25-64', '65+')),
                  .after = age)
  
  # Lines below creates intermediate fastaAll.fasta and metaDataAll.csv in data
  # Optimization: Check job order if want to write fasta and csv
  if (write_fastacsv) {
    print("Writing generated fasta and csv files to data/interm/...")
    
    # Write parameters used to log file
    paramsLog(outputDir = 'data/interm', filename = 'log.txt',
              paramString = sprintf("timestamp = %s\nseed = %d, stratSize = %d",
                                    stamp, seed, stratSize))
    
    print(paste("Writing intermediate fasta to",
                sprintf('data/interm/fastaAll_%s.fasta', stamp)))
    
    seqinr::write.fasta(fastaAll, names(fastaAll),
                        sprintf('data/interm/fastaAll_%s.fasta', stamp))
    
    print(paste("Writing intermediate metadata to",
                sprintf('data/interm/metaDataAll_%s.csv', stamp)))
    
    write.csv(metaDataAll,
              sprintf('data/interm/metaDataAll_%s.csv', stamp),
              row.names = FALSE)
    
    # Refetch fastaAll data using ape::read.FASTA to optimize for kmer analysis
    fastaAll <- read.FASTA(sprintf('data/interm/fastaAll_%s.fasta', stamp))
  }
  
  list(fastaAll, metaDataAll)
}