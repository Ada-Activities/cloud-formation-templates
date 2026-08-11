# Cloud Formation Templates

## Structure

This repository contains the following structure:

- Root Directory:
  - 
  - `README.md` - File structure, usage instructions and directions for adding new Cloud Formation Templates for future livecodes.
  - `deploy.sh` - A script to deploy the cloud formation templates in each subdirectory.
  - `trigger-builds.sh` - A script called from `deploy.sh` that takes build projects in as parameters and  runs them as needed.
  - `teardown.sh` - A script to tear down a specific stack manually after creation.
  - `schedule-teardown.sh` - A script to schedule teardown for a stack after it has been created.
- Sub Directories:
  -  
  -  **REQUIRED**  
     -   `config.conf` - A configuration file that holds variables needed to run the various Cloud Formation templates within the directory. Each conf file will contain variables that may be static (Stack prefixes, Github repos/branches, etc.) and variables that may need to be changed (Region, VPC IDs, Subnet IDs, etc.
     -   `main-stack.yaml` - A Cloud Formation template to build the main stack for a specific livecode.
  -   **OPTIONAL**
      - `bootstrap-ecr.yaml` - A Cloud Formation template to build ECR repositories if needed.
      - `codebuild-projs.yaml` - A Cloud Formation template to build codebuild projects if needed.
      - `frontend-codebuild.yamls` A Cloud Formation template to build out a frontend codebuild if needed.

## Usage

Each subdirectory in this repository contains the files needed to create one or more Cloud Formation Stack(s) to make setup easier and more consistent for Ada Developers Academy Cloud livecodes. Use the following steps to run each set up:

1. Go to the livecode's `config.conf` file. Here you will find all the specific variables that are needed to run different stages. Use the comments to update variables that need to be changed. Variables that need to be changed often include things like the region, vpc ids and subnets. Any variable that is not explicitly called out as one that should be updated can be left as is.
2. Once the variables have been updated, run the command `./deploy.sh <SUBDIRECTORY_NAME>/config.conf`. This command should run all parts of stack creation. If anything fails, an error message will point you in the direction of the correct aws logs to use for debugging purposes.
   1. **NOTE** - If the particular stack uses Codebuild to grab repositories from github, you will be prompted to enter your GITHUB Personal Access Token for authentication purposes.
3. Depending on what is being created, stacks can take anywhere from 5-30 minutes to run. You can keep track of the progress of particular stacks in the AWS Cloud Formation Console. Once a stack has been created, verify the appropriate resources have been created. You should now be able to run the livecode as expected.
4. Once the livecode is finished, use `./teardown.sh <STACK_PREFIX>` or `./schedule-teardown.sh <STACK_PREFIX> <TIME IN MINUTES>` to teardown the stack you created in order to save on costs. The `<STACK_PREFIX>` will always be the name of your directory. Something  like `e-commerce-intro`. 
   
5. Verify the corresponding stack and resources have been removed.

## Future Improvements
- Current templates rely specifically on Ada's E-commerce site for creating ECR repositories and ECS clusters. This will be changed so that generic templates can be deployed effectively as well. 
- This README will be updated to include instructions on how to add new Cloud Formation templates.