import os
from databases import Database
from sqlalchemy import create_engine
from sqlalchemy.orm import declarative_base
from dotenv import load_dotenv

load_dotenv()
DATABASE_URL = os.getenv('DATABASE_URL', 'postgresql://postgres:postgres@db:5432/postgres')
database = Database(DATABASE_URL)
engine = create_engine(DATABASE_URL, pool_pre_ping=True)
Base = declarative_base()