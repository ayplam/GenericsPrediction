# GenericsPrediction
The goal of this project is to predict brand-to-generic conversion times, generic drug release frequency and yearly patterns in generic drug releases. There are four parts to this project:

1. Data Munging
While the FDA database has a collection of all current generic name drugs on the market, it still needs cleaning. 

2. SQL Querying
To decrease the amount of memory usage in IPython Notebook, SQL was used to extract the necessary information for 
all predictive models

3. Model Development
Models were developed to predict the release of a generic name drug based on the release of a brand name drug. In addition,
release frequency and yearly release patterns of generic drugs were analyzed.

4. Data Visualization
No project is ever complete without simple ways to visualize results. JSON files were created in Python for easy viewing
using D3. Results are showcased at ayplam.github.io/fdagx.
