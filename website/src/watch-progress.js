// Count time actually watched, so seeking to the end cannot inflate completion.
export function createWatchProgress(duration=45){
 const buckets=new Set();let previous=null;
 return {
  observe(time,playing,seeking=false){
   if(!playing||seeking){previous=null;return;}
   if(previous!==null&&time>=previous&&time-previous<.75){
    for(let tick=Math.floor(previous*4);tick<Math.floor(time*4);tick++)if(tick>=0&&tick<duration*4)buckets.add(tick);
   }
   previous=time;
  },
  resetPosition(){previous=null;},
  ratio(){return buckets.size/(duration*4);},
  milestones(){const ratio=this.ratio();return [25,50,75].filter(percent=>ratio>=percent/100).map(percent=>'demo_'+percent);},
  complete(){return this.ratio()>=.9;}
 };
}
