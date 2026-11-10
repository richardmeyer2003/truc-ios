/* Shared distance units: the scan processor stores integer millimeters. */
(function(scope){
  'use strict';
  const mile=1609344;
  const targets=[{miles:5,label:'5 miles'},{miles:10,label:'10 miles'},{miles:13.1,label:'Half marathon'},{miles:25,label:'25 miles'},{miles:26.2,label:'Marathon'},{miles:50,label:'50 miles'}].map(t=>({...t,mm:Math.round(t.miles*mile)}));
  function milestone(mm){
    mm=Math.max(0,Number(mm)||0);const achieved=targets.filter(t=>mm>=t.mm),next=targets.find(t=>mm<t.mm)||null;
    const previous=achieved.at(-1)?.mm||0;
    return {achieved,next,remaining:next?next.mm-mm:0,percent:next?Math.min(99,Math.round((mm-previous)/(next.mm-previous)*100)):100};
  }
  function miles(mm){return (Number(mm||0)/mile).toLocaleString('en-US',{minimumFractionDigits:2,maximumFractionDigits:2});}
  function remaining(mm){return (mm>0?Math.max(0.01,Math.round(mm/mile*100)/100):0).toFixed(2);}
  scope.TurcProgress={mile,targets,milestone,miles,remaining};
})(typeof window==='undefined'?globalThis:window);
