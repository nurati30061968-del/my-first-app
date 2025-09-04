#!/usr/bin/env bash
set -e
# Bootstrap script to create an online exam platform scaffold for GitHub Codespaces
# Creates backend (Node/Express), frontend (React Vite), docker-compose with MySQL, and sample data.
# Usage: run this script in an empty Codespace workspace: bash codespaces_exam_system_bootstrap.sh

ROOT=$(pwd)
echo "Creating project scaffold in $ROOT"

# Backend
mkdir -p backend
cat > backend/package.json <<'PKG' {
  "name": "exam-backend",
  "version": "0.1.0",
  "main": "index.js",
  "scripts": {
    "start": "node index.js",
    "dev": "nodemon index.js"
  },
  "dependencies": {
    "bcryptjs": "^2.4.3",
    "body-parser": "^1.20.2",
    "cors": "^2.8.5",
    "exceljs": "^4.3.0",
    "express": "^4.18.2",
    "jsonwebtoken": "^9.0.0",
    "multer": "^1.4.5-lts.1",
    "mysql2": "^3.3.0",
    "sequelize": "^6.32.1"
  },
  "devDependencies": {
    "nodemon": "^2.0.22"
  }
}
PKG

cat > backend/.env <<'ENV'
PORT=4000
JWT_SECRET=replace_this_with_a_strong_secret
DB_HOST=db
DB_USER=root
DB_PASS=example
DB_NAME=exam_db
ENV

cat > backend/index.js <<'JS'
const express = require('express');
const bodyParser = require('body-parser');
const cors = require('cors');
const { initDb, models } = require('./models');
const authRoutes = require('./routes/auth');
const userRoutes = require('./routes/users');
const questionRoutes = require('./routes/questions');
const examRoutes = require('./routes/exams');
const attemptRoutes = require('./routes/attempts');

require('dotenv').config();
const app = express();
app.use(cors());
app.use(bodyParser.json());
app.use('/uploads', express.static('uploads'));

app.use('/api/auth', authRoutes);
app.use('/api/users', userRoutes);
app.use('/api/questions', questionRoutes);
app.use('/api/exams', examRoutes);
app.use('/api/attempts', attemptRoutes);

const PORT = process.env.PORT || 4000;
initDb().then(() => {
  app.listen(PORT, () => console.log(`Backend running on port ${PORT}`));
});
JS

mkdir -p backend/models
cat > backend/models/index.js <<'MOD'
const { Sequelize, DataTypes } = require('sequelize');
require('dotenv').config();

const sequelize = new Sequelize(process.env.DB_NAME, process.env.DB_USER, process.env.DB_PASS, {
  host: process.env.DB_HOST,
  dialect: 'mysql',
  logging: false
});

const User = sequelize.define('User', {
  id: { type: DataTypes.INTEGER, primaryKey: true, autoIncrement: true },
  username: { type: DataTypes.STRING, unique: true },
  password_hash: DataTypes.STRING,
  role: { type: DataTypes.ENUM('admin','teacher','student'), defaultValue: 'student' },
  full_name: DataTypes.STRING,
  meta: DataTypes.JSON
});

const Question = sequelize.define('Question', {
  id: { type: DataTypes.INTEGER, primaryKey: true, autoIncrement: true },
  type: { type: DataTypes.ENUM('mcq_single','mcq_multiple','short_text','essay','file_upload') },
  content: DataTypes.TEXT,
  options: DataTypes.JSON,
  correct_answer: DataTypes.JSON,
  points: { type: DataTypes.FLOAT, defaultValue: 1 }
});

const Exam = sequelize.define('Exam', {
  id: { type: DataTypes.INTEGER, primaryKey: true, autoIncrement: true },
  title: DataTypes.STRING,
  description: DataTypes.TEXT,
  schedule_start: DataTypes.DATE,
  schedule_end: DataTypes.DATE,
  duration_minutes: DataTypes.INTEGER,
  randomize_questions: { type: DataTypes.BOOLEAN, defaultValue: false },
  randomize_options: { type: DataTypes.BOOLEAN, defaultValue: false },
  settings: DataTypes.JSON
});

const ExamQuestion = sequelize.define('ExamQuestion', { position: DataTypes.INTEGER });

const Attempt = sequelize.define('Attempt', {
  id: { type: DataTypes.INTEGER, primaryKey: true, autoIncrement: true },
  status: { type: DataTypes.ENUM('in_progress','submitted','graded','abandoned'), defaultValue: 'in_progress' },
  started_at: DataTypes.DATE,
  submitted_at: DataTypes.DATE,
  time_spent_seconds: DataTypes.INTEGER,
  total_score: DataTypes.FLOAT
});

const Answer = sequelize.define('Answer', {
  answer: DataTypes.JSON,
  attachments: DataTypes.JSON,
  score: DataTypes.FLOAT,
  is_graded: { type: DataTypes.BOOLEAN, defaultValue: false }
});

// relations
User.hasMany(Exam, { as: 'CreatedExams', foreignKey: 'created_by' });
Exam.belongsTo(User, { as: 'Creator', foreignKey: 'created_by' });

Exam.belongsToMany(Question, { through: ExamQuestion });
Question.belongsToMany(Exam, { through: ExamQuestion });

Exam.hasMany(Attempt);
Attempt.belongsTo(Exam);
User.hasMany(Attempt);
Attempt.belongsTo(User);

Attempt.hasMany(Answer);
Answer.belongsTo(Attempt);
Answer.belongsTo(Question);

async function initDb(){
  await sequelize.authenticate();
  await sequelize.sync({ alter: true });
  console.log('DB synced');
}

module.exports = { sequelize, initDb, models: { User, Question, Exam, Attempt, Answer, ExamQuestion } };
MOD

# routes
mkdir -p backend/routes
cat > backend/routes/auth.js <<'RT'
const express = require('express');
const router = express.Router();
const bcrypt = require('bcryptjs');
const jwt = require('jsonwebtoken');
const { models } = require('../models');
require('dotenv').config();

router.post('/register', async (req,res)=>{
  const { username, password, full_name, role } = req.body;
  const hash = await bcrypt.hash(password, 10);
  try{
    const user = await models.User.create({ username, password_hash: hash, full_name, role });
    res.json({ id: user.id, username: user.username });
  }catch(e){ res.status(400).json({ error: e.message }); }
});

router.post('/login', async (req,res)=>{
  const { username, password } = req.body;
  const user = await models.User.findOne({ where: { username } });
  if(!user) return res.status(401).json({ error: 'Invalid' });
  const ok = await bcrypt.compare(password, user.password_hash);
  if(!ok) return res.status(401).json({ error: 'Invalid' });
  const token = jwt.sign({ id: user.id, role: user.role }, process.env.JWT_SECRET, { expiresIn: '8h' });
  res.json({ token, user: { id: user.id, username: user.username, role: user.role, full_name: user.full_name } });
});

module.exports = router;
RT

cat > backend/routes/users.js <<'US'
const express = require('express');
const router = express.Router();
const jwt = require('jsonwebtoken');
const { models } = require('../models');
require('dotenv').config();

function auth(req,res,next){
  const h = req.headers.authorization;
  if(!h) return res.status(401).json({ error: 'no auth' });
  const token = h.split(' ')[1];
  try{ const p = jwt.verify(token, process.env.JWT_SECRET); req.user = p; next(); }catch(e){ res.status(401).json({ error: 'invalid' }) }
}

router.get('/', auth, async (req,res)=>{
  if(req.user.role !== 'admin') return res.status(403).json({ error: 'forbidden' });
  const users = await models.User.findAll();
  res.json(users);
});

module.exports = router;
US

cat > backend/routes/questions.js <<'Q'
const express = require('express');
const router = express.Router();
const multer = require('multer');
const upload = multer({ dest: 'uploads/' });
const ExcelJS = require('exceljs');
const { models } = require('../models');

// create question manual
router.post('/', async (req,res)=>{
  const q = await models.Question.create(req.body);
  res.json(q);
});

// import excel
router.post('/import', upload.single('file'), async (req,res)=>{
  const workbook = new ExcelJS.Workbook();
  await workbook.xlsx.readFile(req.file.path);
  const sheet = workbook.worksheets[0];
  const rows = [];
  sheet.eachRow({ includeEmpty: false }, (row, rowNumber) => {
    if(rowNumber===1) return; // header
    const [type, text, optA, optB, optC, optD, correct, points] = row.values.slice(1);
    const options = [];
    if(optA) options.push({ key: 'A', text: optA });
    if(optB) options.push({ key: 'B', text: optB });
    if(optC) options.push({ key: 'C', text: optC });
    if(optD) options.push({ key: 'D', text: optD });
    rows.push({ type, content: text, options, correct_answer: correct ? correct.toString().split('|') : [], points: points||1 });
  });
  const created = [];
  for(const r of rows){ created.push(await models.Question.create(r)); }
  res.json({ imported: created.length });
});

router.get('/', async (req,res)=>{ const qs = await models.Question.findAll(); res.json(qs); });

module.exports = router;
Q

cat > backend/routes/exams.js <<'E'
const express = require('express');
const router = express.Router();
const { models } = require('../models');

router.post('/', async (req,res)=>{
  const e = await models.Exam.create(req.body);
  res.json(e);
});

router.post('/:id/assign', async (req,res)=>{
  const exam = await models.Exam.findByPk(req.params.id);
  if(!exam) return res.status(404).json({ error: 'not found' });
  const { questionIds } = req.body;
  await exam.setQuestions(questionIds);
  res.json({ ok: true });
});

router.get('/', async (req,res)=>{ const exams = await models.Exam.findAll({ include: [{ model: models.Question }] }); res.json(exams); });

module.exports = router;
E

cat > backend/routes/attempts.js <<'A'
const express = require('express');
const router = express.Router();
const jwt = require('jsonwebtoken');
const { models } = require('../models');
require('dotenv').config();

function auth(req,res,next){
  const h = req.headers.authorization; if(!h) return res.status(401).json({ error: 'no auth' });
  const token = h.split(' ')[1]; try{ const p = jwt.verify(token, process.env.JWT_SECRET); req.user = p; next(); }catch(e){ res.status(401).json({ error: 'invalid' }) }
}

// start attempt
router.post('/:examId/start', auth, async (req,res)=>{
  const exam = await models.Exam.findByPk(req.params.examId, { include: models.Question });
  if(!exam) return res.status(404).json({ error: 'exam not found' });
  const attempt = await models.Attempt.create({ ExamId: exam.id, UserId: req.user.id, started_at: new Date() });
  // attach empty answers
  const qs = await exam.getQuestions();
  for(const q of qs){ await models.Answer.create({ AttemptId: attempt.id, QuestionId: q.id, answer: null }); }
  res.json({ attemptId: attempt.id });
});

// autosave answers
router.post('/:attemptId/autosave', auth, async (req,res)=>{
  const attempt = await models.Attempt.findByPk(req.params.attemptId);
  if(!attempt) return res.status(404).json({ error: 'not found' });
  const { answers } = req.body; // [{questionId, answer}]
  for(const a of answers){
    const row = await models.Answer.findOne({ where: { AttemptId: attempt.id, QuestionId: a.questionId } });
    if(row){ row.answer = a.answer; await row.save(); }
  }
  res.json({ ok: true });
});

// submit
router.post('/:attemptId/submit', auth, async (req,res)=>{
  const attempt = await models.Attempt.findByPk(req.params.attemptId, { include: [{ model: models.Answer, include: [models.Question] }] });
  if(!attempt) return res.status(404).json({ error: 'not found' });
  attempt.submitted_at = new Date(); attempt.status = 'submitted';
  // grade MCQ
  let total = 0;
  for(const ans of attempt.Answers){
    const q = ans.Question;
    if(q.type === 'mcq_single' || q.type === 'mcq_multiple'){
      const correct = q.correct_answer || [];
      const given = ans.answer || [];
      // simple grading: full credit if arrays equal (order-insensitive)
      const isEqual = Array.isArray(given) && Array.isArray(correct) && given.length === correct.length && given.every(v=>correct.includes(v));
      ans.score = isEqual ? q.points : 0; ans.is_graded = true; await ans.save(); total += ans.score || 0;
    }
  }
  attempt.total_score = total; await attempt.save();
  res.json({ ok: true, total });
});

// get attempt results
router.get('/:attemptId', auth, async (req,res)=>{
  const attempt = await models.Attempt.findByPk(req.params.attemptId, { include: [{ model: models.Answer, include: [models.Question] }, models.User] });
  res.json(attempt);
});

module.exports = router;
A

# Frontend
mkdir -p frontend
cat > frontend/package.json <<'FPKG' {
  "name": "exam-frontend",
  "version": "0.1.0",
  "private": true,
  "scripts": {
    "dev": "vite",
    "build": "vite build",
    "start": "vite preview"
  },
  "dependencies": {
    "axios": "^1.4.0",
    "react": "^18.2.0",
    "react-dom": "^18.2.0",
    "react-router-dom": "^6.14.1"
  },
  "devDependencies": {
    "@vitejs/plugin-react": "^4.1.0",
    "vite": "^5.2.0"
  }
}
FPKG

cat > frontend/index.html <<'HTML'
<!doctype html>
<html>
  <head>
    <meta charset="utf-8" />
    <meta name="viewport" content="width=device-width, initial-scale=1.0" />
    <title>Exam Frontend</title>
  </head>
  <body>
    <div id="root"></div>
    <script type="module" src="/src/main.jsx"></script>
  </body>
</html>
HTML

mkdir -p frontend/src
cat > frontend/src/main.jsx <<'M'
import React from 'react'
import { createRoot } from 'react-dom/client'
import { BrowserRouter, Routes, Route, Link, useNavigate } from 'react-router-dom'
import axios from 'axios'

axios.defaults.baseURL = 'http://localhost:4000/api'

function Login(){
  const [u,setU]=React.useState(''); const [p,setP]=React.useState(''); const nav = useNavigate();
  async function submit(){
    const r = await axios.post('/auth/login',{ username:u, password:p });
    localStorage.setItem('token', r.data.token);
    axios.defaults.headers.common['Authorization'] = `Bearer ${r.data.token}`;
    nav('/student');
  }
  return (<div style={{padding:20}}>
    <h2>Login</h2>
    <input placeholder="username" value={u} onChange={e=>setU(e.target.value)} /><br/>
    <input placeholder="password" type="password" value={p} onChange={e=>setP(e.target.value)} /><br/>
    <button onClick={submit}>Login</button>
  </div>)
}

function Student(){
  const [exams,setExams]=React.useState([]);
  React.useEffect(()=>{ axios.get('/exams').then(r=>setExams(r.data)); },[]);
  return (<div style={{padding:20}}>
    <h2>Student Dashboard</h2>
    <ul>{exams.map(e=>(<li key={e.id}><Link to={`/exam/${e.id}`}>{e.title}</Link></li>))}</ul>
  </div>)
}

function ExamTaker(){
  const { pathname } = window.location;
  const id = pathname.split('/').pop();
  const [attemptId,setAttemptId]=React.useState(null);
  const [questions,setQuestions]=React.useState([]);
  React.useEffect(()=>{
    axios.post(`/attempts/${id}/start`).then(r=>{ setAttemptId(r.data.attemptId); axios.get(`/exams`).then(res=>{
      const ex = res.data.find(x=>x.id==id);
      if(ex && ex.Questions) setQuestions(ex.Questions);
    }); });
  },[]);

  React.useEffect(()=>{
    const t = setInterval(()=>{
      if(!attemptId) return;
      // gather answers from DOM
      const answers = questions.map(q=>{
        const el = document.querySelector(`[name=ans-${q.id}]`);
        if(!el) return { questionId: q.id, answer: null };
        if(q.type.startsWith('mcq')){
          const opts = Array.from(document.querySelectorAll(`[name=ans-${q.id}]:checked`)).map(i=>i.value);
          return { questionId: q.id, answer: opts };
        }else{
          return { questionId: q.id, answer: el.value };
        }
      });
      axios.post(`/attempts/${attemptId}/autosave`, { answers }).catch(()=>{});
    }, 15000);
    return ()=>clearInterval(t);
  },[attemptId, questions]);

  async function submit(){
    await axios.post(`/attempts/${attemptId}/submit`);
    alert('submitted');
  }

  return (<div style={{padding:20}}>
    <h2>Exam {id}</h2>
    {questions.map(q=> (
      <div key={q.id} style={{border:'1px solid #ccc',padding:10,margin:10}}>
        <div dangerouslySetInnerHTML={{__html: q.content}} />
        {q.options && q.options.map(o=>(
          <div key={o.key}><label><input type={q.type==='mcq_multiple'?'checkbox':'radio'} name={`ans-${q.id}`} value={o.key} /> {o.text}</label></div>
        ))}
        {(!q.options) && <textarea name={`ans-${q.id}`} rows={3}></textarea>}
      </div>
    ))}
    <button onClick={submit}>Submit</button>
  </div>)
}

function App(){
  React.useEffect(()=>{
    const t = localStorage.getItem('token'); if(t) axios.defaults.headers.common['Authorization'] = `Bearer ${t}`;
  },[]);
  return (<BrowserRouter>
    <Routes>
      <Route path='/' element={<Login/>} />
      <Route path='/student' element={<Student/>} />
      <Route path='/exam/:id' element={<ExamTaker/>} />
    </Routes>
  </BrowserRouter>)
}

createRoot(document.getElementById('root')).render(<App />)
M

# Docker-compose
cat > docker-compose.yml <<'DC'
version: '3.8'
services:
  db:
    image: mysql:8.0
    environment:
      MYSQL_ROOT_PASSWORD: example
      MYSQL_DATABASE: exam_db
    volumes:
      - db_data:/var/lib/mysql
    ports:
      - '3306:3306'
  backend:
    build: ./backend
    volumes:
      - ./backend:/usr/src/app
      - ./backend/uploads:/usr/src/app/uploads
    ports:
      - '4000:4000'
    environment:
      - DB_HOST=db
      - DB_USER=root
      - DB_PASS=example
      - DB_NAME=exam_db
      - JWT_SECRET=replace_this_with_a_strong_secret
    depends_on:
      - db
  frontend:
    build: ./frontend
    volumes:
      - ./frontend:/usr/src/app
    ports:
      - '5173:5173'
    depends_on:
      - backend
volumes:
  db_data:
DC

# simple Dockerfiles
cat > backend/Dockerfile <<'BDF'
FROM node:18
WORKDIR /usr/src/app
COPY package*.json ./
RUN npm install --production
COPY . .
EXPOSE 4000
CMD [ "node", "index.js" ]
BDF

cat > frontend/Dockerfile <<'FDF'
FROM node:18
WORKDIR /usr/src/app
COPY package*.json ./
RUN npm install
COPY . .
EXPOSE 5173
CMD [ "npm", "run", "dev" ]
FDF

# .gitignore
cat > .gitignore <<'GI'
node_modules
backend/node_modules
frontend/node_modules
.env
uploads
GI

# Init message

echo "Bootstrap complete.\nNext steps:\n1) Open this repository in GitHub Codespaces.\n2) In the Codespace terminal run: docker-compose up --build\n3) Wait for MySQL to initialize and backend to report 'DB synced'.\n4) Open http://localhost:5173 in the Codespace forwarded port or use Codespaces preview.\n\nNotes: \n- Default admin/student users are not created by script. Use POST /api/auth/register to create users.\n- Excel import: upload .xlsx to POST /api/questions/import (multipart form-data 'file').\n- This scaffold implements core flows: auth, question import, exam creation, start attempt, autosave, submit, basic MCQ grading, and a minimal frontend exam taker with autosave every 15s.\n\nIf you want, run the following to install deps now (optional):\n  cd backend && npm install && cd ../frontend && npm install\"
