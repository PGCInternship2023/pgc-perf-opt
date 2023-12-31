# File: wordcloud_app.R

# INSTALL AND LOAD PACKAGES ################################
options(repos = "https://cloud.r-project.org/")

# Installs pacman ("package manager") if needed
if (!require("pacman"))
  install.packages("pacman")
library(pacman)

### ATTN: IN LINUX SYSTEMS, CONSULT README FOR ADDITIONAL PREREQUISITES
### BEFORE RUNNING ANY SCRIPT. ISSUE: tidyverse installation.
### This is a non-issue if code is ran within cpu.Dockerfile.
### This cannot be scripted because this requires sudo priveleges.

# Install xml2 in advance to prep for tidyverse installation in Linux.
# Note that in Windows RStudio, this is installed by default.
# If you're getting xml2 errors on Windows, you broke something lol.
if (pacman::p_detectOS() == "Linux" && !pacman::p_exists(xml2, local = TRUE)) {
  install.packages("xml2", dependencies = TRUE, INSTALL_opts = c("--no-lock"))
  pacman::p_load(xml2)
}

# Use pacman to load add-on packages as desired.
pacman::p_load(plyr, GGally, ggthemes, ggvis, plotly, psych,
               htmlwidgets, rio, markdown, shiny, tidyverse,
               ape, seqinr, kmer, validate, gsubfn,
               Rtsne, tsne, umap, factoextra, scales,
               RColorBrewer, ggfortify, devtools,
               ggdendro, dendextend, cluster, colorspace,
               microbenchmark, data.table, highcharter,
               wordcloud, tm)
if (!require(ggbiplot))
  install_github("vqv/ggbiplot", upgrade = FALSE, quiet = TRUE)
pacman::p_load(ggbiplot)
# NOTE: This app currently only works when launched from pgc-perf-opt.Rproject.
# TODO: Publish to shinyapps.io with data loaded from somewhere else.

# Define UI for app that draws a word cloud
ui <- fluidPage(
  shinyjs::useShinyjs(),
  # App title
  titlePanel("k-mer word clouds"),
  # Sidebar layout with input and output definitions
  sidebarLayout(
    # Sidebar panel for inputs
    sidebarPanel(
      # Select strat_size, hardcoded available strat_sizes only
      p("Note: ", strong("data/kmers/"), "must be populated with the prescribed, pre-generated kmer files."),
      p("Only the top 200 most frequent k-mers will be displayed."),
      selectInput(inputId = "strat_size",
                  label = "Select stratum size",
                  choices = list(100,250,500,750,1000,1500,2000)),
      textOutput(outputId = "numsamples"),
      hr(),
      radioButtons(inputId = "k",
                   label = "Select k-mer size",
                   choices = list(3,5,7),
                   inline = TRUE),
      tags$div(title="This corresponds to the strain metadata attribute. You can type here.",
               selectizeInput("sample_name", label = "Select sample name", choices = NULL)
      ),
      tags$div(title="Whether to compute the wordcloud using the mean of the entire k-mer matrix",
               checkboxInput(inputId = "show_all",
                             label = "Show wordcloud for full dataset",
                             value = FALSE)
      ),
      hr(),
      tableOutput(outputId = "summary")
    ),
    
    # Main panel for displaying outputs ----
    mainPanel(
      
      plotOutput(outputId = "wordcloud")

    )
  )
)

seed <- 777

# Define server logic required to compute and render wordcloud ----
server <- function(input, output, session) {
  kmer_df <- reactiveVal()
  
  data <- reactive({
    path <- sprintf("../../data/kmers/kmer_%s_%s.csv", input$k, input$strat_size)
    kmer_df(readr::read_csv(path))
    strains <- lapply(as.list(select(kmer_df(), strain)), sort)
    updateSelectizeInput(session, "sample_name", choices = strains, server = TRUE)
    output$numsamples <- renderText(sprintf("This stratum size yields %s samples.", nrow(kmer_df())))
  })
  
  figure <- reactive({
    data()
    df <- kmer_df()
    if(!is.null(input$sample_name)) {
      if(!input$show_all) {
        sample <- df %>%
          dplyr::filter(strain == input$sample_name) %>%
          dplyr::select(!(strain:length(df)))
        sample <- t(sample)
        sample <- sample[order(sample,decreasing=TRUE),]
        summary_tbl <- as.data.frame(names(sample))
        summary_tbl["frequency"] <- sample
        if (length(colnames(summary_tbl)) == 2)
          colnames(summary_tbl) <- c("kmer", "frequency")
        output$summary <- renderTable({summary_tbl})
        if(length(sample)>0) {
          set.seed(seed)
          fig <- wordcloud(words=names(sample), freq=sample, min.freq=1,
                           max.words=200, random.order=FALSE, rot.per=0.35,
                           colors=brewer.pal(8, "Dark2"))
          set.seed(NULL)
          fig
        }
      } else {
        sample <- df %>%
          dplyr::select(!(strain:length(df))) %>%
          dplyr::summarise(dplyr::across(dplyr::everything(), mean))
        sample <- t(sample[1,])
        sample <- sample[order(sample,decreasing=TRUE),]
        summary_tbl <- as.data.frame(names(sample))
        summary_tbl["frequency"] <- sample
        colnames(summary_tbl) <- c("kmer", "frequency")
        output$summary <- renderTable({summary_tbl})
        if(length(sample)>0) {
          set.seed(seed)
          fig <- wordcloud(words=names(sample), freq=sample, min.freq=1,
                           max.words=200, random.order=FALSE, rot.per=0.35,
                           colors=brewer.pal(8, "Dark2"))
          set.seed(NULL)
          fig
        }
      }
    }
  })
  
  observe({
    if((input$show_all == TRUE)) {
      shinyjs::disable("sample_name")
    } else {
      shinyjs::enable("sample_name")
    }
  })
  
  k <- reactive({
    if (input$k==3) 500
    else if (input$k==5) 1200
    else if (input$k==7) 1200
  })

  output$wordcloud <- renderPlot({figure()},
                                 height = k, width = k)
  
}

shinyApp(ui = ui, server = server)