'use strict';
const duty=require('../duty/service');
async function buildOrder(id) {const order=await duty.getPrintableOrder(id);return order ? {...order,printedAt:new Date()} : null;}
module.exports={buildOrder};
