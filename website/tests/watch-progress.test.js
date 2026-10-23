import test from 'node:test';
import assert from 'node:assert/strict';
import {createWatchProgress} from '../src/watch-progress.js';
import {campaignFrom} from '../src/analytics.js';
test('seeking directly to the end does not earn watch milestones',()=>{const p=createWatchProgress();p.observe(0,true);p.observe(40,true,true);p.observe(44.9,true);p.observe(45,false);assert.deepEqual(p.milestones(),[]);assert.equal(p.complete(),false);});
test('actual playback earns milestones and replay does not double count time',()=>{const p=createWatchProgress();for(let t=0;t<=23;t+=.25)p.observe(t,true);assert.deepEqual(p.milestones(),['demo_25','demo_50']);p.resetPosition();for(let t=0;t<=23;t+=.25)p.observe(t,true);assert.equal(p.complete(),false);for(let t=23;t<=45;t+=.25)p.observe(t,true);assert.equal(p.complete(),true);});
test('paused time is not watched time',()=>{const p=createWatchProgress();p.observe(0,true);p.observe(20,false);p.observe(40,true);p.observe(40.5,true);assert.ok(p.ratio()<.02);});
test('campaign collection is limited to bounded labels',()=>{const c=campaignFrom('?utm_source=linkedin&utm_campaign=team%20pilot&email=person%40example.com&fbclid=secret');assert.equal(c.utm_source,'linkedin');assert.equal(c.utm_campaign,'team pilot');assert.equal('email' in c,false);assert.equal('fbclid' in c,false);});
