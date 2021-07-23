var obj = JSON.parse($response.body);
obj={
    "code": 0, 
    "result": {
        "SPEED_VIP_KM4": {
            "resourceId": "", 
            "residualSecond": "999999", 
            "rightsType": "SPEED_VIP_KM4", 
            "description": null, 
            "beginTime": "2021-07-22", 
            "endTime": "2029-07-22", 
            "deviceOverflow": "0", 
            "status": "1", 
            "overdueSecond": "0"
        }, 
        "RELIABLE_VIP_KM4": {
            "resourceId": "", 
            "residualSecond": "999999", 
            "rightsType": "RELIABLE_VIP_KM4", 
            "description": null, 
            "beginTime": "2021-07-22", 
            "endTime": "2029-07-22", 
            "deviceOverflow": "0", 
            "status": "1", 
            "overdueSecond": "0"
        }, 
        "RELIABLE_VIP_KM1": {
            "resourceId": "", 
            "residualSecond": "999999", 
            "rightsType": "RELIABLE_VIP_KM1", 
            "description": null, 
            "beginTime": "2021-07-22", 
            "endTime": "2029-07-22", 
            "deviceOverflow": "0", 
            "status": "1", 
            "overdueSecond": "0"
        }, 
        "SVIP_LIVECAMP": {
            "resourceId": "", 
            "residualSecond": "999999", 
            "rightsType": "SVIP_LIVECAMP", 
            "description": null, 
            "beginTime": "2021-07-22", 
            "endTime": "2029-07-22", 
            "deviceOverflow": "0", 
            "status": "5", 
            "overdueSecond": "0"
        }, 
        "VIP": {
            "resourceId": "", 
            "residualSecond": "999999", 
            "rightsType": "VIP", 
            "description": null, 
            "beginTime": "2021-07-22", 
            "endTime": "2029-07-22", 
            "deviceOverflow": "0", 
            "status": "1", 
            "overdueSecond": "0"
        }, 
        "SVIP": {
            "resourceId": "", 
            "residualSecond": "999999", 
            "rightsType": "SVIP", 
            "description": null, 
            "beginTime": "2021-07-22", 
            "endTime": "2029-07-22", 
            "deviceOverflow": "0", 
            "status": "5", 
            "overdueSecond": "0"
        }, 
        "SPEED_VIP_KM1": {
            "resourceId": "", 
            "residualSecond": "999999", 
            "rightsType": "SPEED_VIP_KM1", 
            "description": null, 
            "beginTime": "2021-07-22", 
            "endTime": "2029-07-22", 
            "deviceOverflow": "0", 
            "status": "1", 
            "overdueSecond": "0"
        }, 
        "SPEED_VIP_KM2": {
            "resourceId": "", 
            "residualSecond": "999999", 
            "rightsType": "SPEED_VIP_KM2", 
            "description": null, 
            "beginTime": "2021-07-22", 
            "endTime": "2029-07-22", 
            "deviceOverflow": "0", 
            "status": "1", 
            "overdueSecond": "0"
        }, 
        "SPEED_VIP_KM3": {
            "resourceId": "", 
            "residualSecond": "999999", 
            "rightsType": "SPEED_VIP_KM3", 
            "description": null, 
            "beginTime": "2021-07-22", 
            "endTime": "2029-07-22", 
            "deviceOverflow": "0", 
            "status": "1", 
            "overdueSecond": "0"
        }
    }, 
    "msg": "ok"
};
$done({body: JSON.stringify(obj)});
