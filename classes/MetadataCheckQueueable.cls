public with sharing class MetadataCheckQueueable implements Queueable, Database.AllowsCallouts {

    /**
     * How many callouts to do in one transaction - governor limit is 100
     */
    private static Integer MAX_CALLOUTS = 90;

    /**
     * Map of Object ID's to their Developer Name
     */
    private Map<String, String> objectIdMap;

    /**
     * Set of Field ID's that have been uncheked
     * This is a Set and not a List so we can remove elements
     */
    private Set<String> fieldIds;

    /**
     * List of Strings that will contain our error messages for the email
     */
    private List<String> foundList;

    /**
     * How many custom fields are local to this org - populated on first run of Queueable only
     */
    private Integer totalFields;

    /**
     * Constructor called on initial job creation
     * @param  inObjectIdMap Map of Object ID's to Developer Names
     * @param  inFieldIds    Set of Field ID's to check
     */
    public MetadataCheckQueueable(Map<String, String> inObjectIdMap, Set<String> inFieldIds) {
        this.objectIdMap = inObjectIdMap;
        this.fieldIds = inFieldIds;
        this.totalFields = inFieldIds.size();
        this.foundList = new List<String>();
    }

    /**
     * Constructor called on subsequent job chains
     * @param  inObjectIdMap Map of Object ID's to Developer Names
     * @param  inFieldIds    Set of Field ID's that haven't been checked yet
     * @param  inTotal       Total Number of fields in original call
     * @param  inFound       Current list of errors
     */
    public MetadataCheckQueueable(Map<String, String> inObjectIdMap, Set<String> inFieldIds, Integer inTotal, List<String> inFound) {
        this.objectIdMap = inObjectIdMap;
        this.fieldIds = inFieldIds;
        this.totalFields = inTotal;
        this.foundList = inFound;
    }

    public void execute(QueueableContext context) {

        // As we go through fields, we remove their ID's from this set for the next invocation of the Queueable
        Set<String> nextFieldIds = new Set<String>(this.fieldIds);

        Integer count = 0;
        for (String fieldId : this.fieldIds) {
            String metadataQuery = 'SELECT Id, DeveloperName, TableEnumOrId, Metadata FROM CustomField WHERE Id = \'' + fieldId + '\'';
            Map<String, Object> metadataBody = MetadataCheckService.doToolingQuery(metadataQuery);

            if (metadataBody != null) {
                List<Object> metadataRecords = (List<Object>)metadataBody.get('records');
                Map<String, Object> record = (Map<String, Object>)metadataRecords[0];
                Map<String, Object> metadata = (Map<String, Object>)record.get('Metadata');

                String description = (String)metadata.get('description');
                if ((description == null) || (String.isBlank(description))) {
                    String tableEnumOrId = (String)record.get('TableEnumOrId');
                    String objectName = tableEnumOrId;
                    if (this.objectIdMap.keySet().contains(tableEnumOrId)) {
                        objectName = this.objectIdMap.get(tableEnumOrId);
                    }
                    this.foundList.add(objectName + '.' + (String)record.get('DeveloperName') + '__c is missing Description');
                }
            }

            nextFieldIds.remove(fieldId);
            count++;
            if (count > MAX_CALLOUTS) {
                // We've reached our limit. Break out of the for loop.
                break;
            }
        }

        if (!nextFieldIds.isEmpty()) {
            // Pass along the information with an updated list of fields to check to a new chain
            MetadataCheckQueueable mcq = new MetadataCheckQueueable(this.objectIdMap, nextFieldIds, this.totalFields, this.foundList);
            System.enqueueJob(mcq);
        } else {
            sendEmail();
        }

    }

    /**
     * Send an email to the running user when the queueable is completed
     */
    private void sendEmail() {

        Messaging.SingleEmailMessage mail = new Messaging.SingleEmailMessage();
        mail.setToAddresses(new List<String>{UserInfo.getUserEmail()});
        mail.setSubject('Metadata Check Complete');

        String textBody = 'Check of custom metadata complete. Out of ' + this.totalFields + ' fields, there were ' + this.foundList.size() + ' pieces of missing metadata.\n\n';
        if (!this.foundList.isEmpty()) {
            this.foundList.sort();
            textBody += String.join(this.foundList, '\n');
        }
        mail.setPlainTextBody(textBody);

        Messaging.sendEmail(new List<Messaging.SingleEmailMessage>{mail});

    }

}