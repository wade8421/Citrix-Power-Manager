# Citrix-Power-Mananger
Citrix Smart Tools will be end of life on 5/31/2019 unless you are willing to move your Citrix management servers over to Citrix Cloud.  We have heavily relied on the "Smart Scale" tool as our infrastrutures ran in public cloud environments.  It appears that unless you want to pay Citrix to run your delivery controllers and Storefronts, then you can't use their tool.

For those of us that don't wish to give up control of these services, or simply can't for company policy reason, I have created this powershell script that can be run as a service from any machine with LAN level access to you your delivery controllers or even on your delivery controller.

## Getting Started

These instructions will get you a copy of the project up and running on your local machine for development and testing purposes. See deployment for notes on how to deploy the project on a live system.

### Prerequisites

* Powrshell 2.0
* Citrix SnapIns for Powershell

### Installing

Recommended Install:

Run the exe to install the service.
Change the user that runs the script to a service account that has access to administer your citrix environment.
The service will make the config file needed.  Please modify the settings to meet your needs.  I have tried to make it match the settings on Smart Scale tool as closely as possible.


## Authors

* **Wade Dickens** - *Initial work* - [South Florida IT Consulting](https://www.sflitconsulting.com)

See also the list of [contributors](https://github.com/your/project/contributors) who participated in this project.

## License

This project has no license.  Do what you will with it.  Maybe provide some feedback so we can make it better.

